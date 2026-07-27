class_name NoirApiConnector
extends Node
## HTTP-клиент к LLM. Автозагрузка: `Api`.
##
## Эндпоинт по умолчанию: https://models.inference.ai.azure.com/chat/completions
## Модель по умолчанию: gpt-4.1. Авторизация: `Authorization: Bearer <token>`.
##
## Почему это не падает никогда (в GDScript нет try/catch):
##  * каждый запрос — объект [ApiJob] с полем-результатом, а не исключение;
##  * транспортные сбои, таймауты, 429 и 5xx уходят в ретрай с экспоненциальной
##    задержкой и джиттером, 4xx — в немедленный отказ без ретраев;
##  * отсутствие токена/сети — не ошибка, а штатный код `OFFLINE`, по которому
##    `CrimeDirector` переключается на локальный генератор;
##  * тело ответа парсится защищённо: markdown-обёртки снимаются, JSON ищется
##    поиском сбалансированных скобок, при провале — код `BAD_JSON`.

enum Code {
	OK,
	OFFLINE,        ## нет токена или API выключен в настройках
	TRANSPORT,      ## HTTPRequest не смог выполнить запрос
	TIMEOUT,
	HTTP_ERROR,     ## сервер ответил не-2xx
	BAD_JSON,       ## ответ не разбирается как JSON
	EMPTY,          ## пустой content
	CANCELLED,
}

const CODE_NAMES: Dictionary = {
	Code.OK: "OK",
	Code.OFFLINE: "OFFLINE",
	Code.TRANSPORT: "TRANSPORT",
	Code.TIMEOUT: "TIMEOUT",
	Code.HTTP_ERROR: "HTTP_ERROR",
	Code.BAD_JSON: "BAD_JSON",
	Code.EMPTY: "EMPTY",
	Code.CANCELLED: "CANCELLED",
}

const RETRYABLE_STATUS: PackedInt32Array = [408, 409, 425, 429, 500, 502, 503, 504, 522, 524]
const BASE_BACKOFF_SEC := 1.4
const MAX_BACKOFF_SEC := 24.0


## Одна задача к API. Ждать результат: `var result: Dictionary = await job.finished`
class ApiJob extends RefCounted:
	signal finished(result: Dictionary)

	var id: int = 0
	var label: String = ""
	var messages: Array = []
	var model: String = ""
	var temperature: float = 0.85
	var max_tokens: int = 4096
	var timeout_sec: float = 45.0
	var max_attempts: int = 4
	var expect_json: bool = true

	var attempts: int = 0
	var cancelled: bool = false
	var started_msec: int = 0
	var result: Dictionary = {}

	func is_done() -> bool:
		return not result.is_empty()

	func cancel() -> void:
		cancelled = true


signal job_started(job_id: int, label: String)
signal job_retrying(job_id: int, attempt: int, delay_sec: float)
signal job_finished(job_id: int, ok: bool, code: int)

var _queue: Array[ApiJob] = []
var _active: int = 0
var _next_id: int = 1
var _in_flight: Dictionary = {}   # job_id -> ApiJob


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var token_present: bool = GameConfig.has_llm_token()
	Log.info("Api", "Коннектор LLM готов", {
		"endpoint": GameConfig.get_string("api", "endpoint"),
		"model": GameConfig.get_string("api", "model"),
		"токен": "есть" if token_present else "НЕТ (оффлайн)",
	})


## API доступен только если он включён в настройках и есть токен.
func is_available() -> bool:
	return GameConfig.get_bool("api", "enabled") and GameConfig.has_llm_token()


func pending_count() -> int:
	return _queue.size() + _active


## Ставит запрос в очередь. Возвращает [ApiJob]; результат — через `await job.finished`.
## [param options]: label, model, temperature, max_tokens, timeout_sec,
## max_attempts, expect_json.
func submit(messages: Array, options: Dictionary = {}) -> ApiJob:
	var job := ApiJob.new()
	job.id = _next_id
	_next_id += 1
	job.label = str(options.get("label", "chat"))
	job.messages = messages.duplicate(true)
	job.model = str(options.get("model", GameConfig.get_string("api", "model")))
	job.temperature = float(options.get("temperature", GameConfig.get_float("api", "temperature")))
	job.max_tokens = int(options.get("max_tokens", GameConfig.get_int("api", "max_tokens")))
	job.timeout_sec = float(options.get("timeout_sec", GameConfig.get_float("api", "timeout_sec")))
	job.max_attempts = maxi(1, int(options.get("max_attempts", GameConfig.get_int("api", "max_attempts"))))
	job.expect_json = bool(options.get("expect_json", true))
	job.started_msec = Time.get_ticks_msec()

	if messages.is_empty():
		_finish(job, _make_result(Code.OFFLINE, 0, "", null, "пустой список сообщений", job))
		return job

	if not is_available():
		var reason: String = "API выключен в настройках" if not GameConfig.get_bool("api", "enabled") else "токен LLM отсутствует"
		Log.warn("Api", "Запрос не отправлен — работаем оффлайн", {"job": job.id, "причина": reason})
		_finish(job, _make_result(Code.OFFLINE, 0, "", null, reason, job))
		return job

	_queue.append(job)
	_pump()
	return job


## Удобная обёртка: сразу возвращает результат.
func request_chat(messages: Array, options: Dictionary = {}) -> Dictionary:
	var job: ApiJob = submit(messages, options)
	if job.is_done():
		return job.result
	return await job.finished


func cancel_all() -> void:
	for job: ApiJob in _queue:
		job.cancel()
		_finish(job, _make_result(Code.CANCELLED, 0, "", null, "очередь сброшена", job))
	_queue.clear()
	for key: Variant in _in_flight.keys():
		var job: ApiJob = _in_flight[key]
		job.cancel()
	Log.info("Api", "Все запросы отменены")


# ---------------------------------------------------------------- диспетчер

func _pump() -> void:
	var limit: int = maxi(1, GameConfig.get_int("api", "max_concurrent"))
	while _active < limit and not _queue.is_empty():
		var job: ApiJob = _queue.pop_front()
		if job.cancelled:
			_finish(job, _make_result(Code.CANCELLED, 0, "", null, "отменён до старта", job))
			continue
		_active += 1
		_in_flight[job.id] = job
		_dispatch(job)


func _dispatch(job: ApiJob) -> void:
	job.attempts += 1

	var http := HTTPRequest.new()
	http.timeout = maxf(5.0, job.timeout_sec)
	http.accept_gzip = true
	http.use_threads = true
	add_child(http)

	http.request_completed.connect(_on_request_completed.bind(job, http), CONNECT_ONE_SHOT)

	var endpoint: String = GameConfig.get_string("api", "endpoint")
	if endpoint.is_empty():
		endpoint = NoirGameConfig.DEFAULT_ENDPOINT

	var body: Dictionary = {
		"model": job.model,
		"messages": job.messages,
		"temperature": clampf(job.temperature, 0.0, 2.0),
		"max_tokens": clampi(job.max_tokens, 256, 32768),
	}
	if job.expect_json:
		body["response_format"] = {"type": "json_object"}

	var headers: PackedStringArray = [
		"Content-Type: application/json",
		"Accept: application/json",
		"User-Agent: NeonNoirShadowsOfRain/1.0 (Godot)",
		"Authorization: Bearer %s" % GameConfig.resolve_llm_token(),
	]

	job_started.emit(job.id, job.label)
	Log.debug("Api", "Отправка запроса", {
		"job": job.id, "label": job.label, "попытка": job.attempts,
		"model": job.model, "endpoint": endpoint,
	})

	var send_error: int = http.request(endpoint, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if send_error != OK:
		_cleanup_http(http)
		_handle_failure(job, Code.TRANSPORT, 0, "HTTPRequest.request вернул код %d" % send_error)


func _on_request_completed(result: int, status: int, headers: PackedStringArray, body: PackedByteArray, job: ApiJob, http: HTTPRequest) -> void:
	_cleanup_http(http)

	if job.cancelled:
		_settle(job, _make_result(Code.CANCELLED, status, "", null, "отменён во время выполнения", job))
		return

	if result == HTTPRequest.RESULT_TIMEOUT:
		_handle_failure(job, Code.TIMEOUT, status, "таймаут %.0f с" % job.timeout_sec)
		return

	if result != HTTPRequest.RESULT_SUCCESS:
		_handle_failure(job, Code.TRANSPORT, status, "транспортная ошибка (result=%d)" % result)
		return

	var raw: String = body.get_string_from_utf8()

	if status < 200 or status >= 300:
		var detail: String = _extract_api_error(raw)
		if RETRYABLE_STATUS.has(status):
			# Сервер лучше нас знает, сколько ждать: Retry-After или текст ошибки.
			_handle_failure(job, Code.HTTP_ERROR, status, detail, _retry_delay_hint(headers, detail))
		else:
			Log.error("Api", "Сервер отказал без права на ретрай", {"job": job.id, "status": status, "деталь": detail})
			_settle(job, _make_result(Code.HTTP_ERROR, status, "", null, detail, job))
		return

	var envelope: Variant = JSON.parse_string(raw)
	if not (envelope is Dictionary):
		_handle_failure(job, Code.BAD_JSON, status, "конверт ответа не является объектом JSON")
		return

	var content: String = _extract_content(envelope as Dictionary)
	if content.strip_edges().is_empty():
		_handle_failure(job, Code.EMPTY, status, "модель вернула пустой content")
		return

	if GameConfig.get_bool("api", "log_raw_bodies"):
		Log.trace("Api", "Сырой content", {"job": job.id, "content": content})

	var parsed: Variant = null
	if job.expect_json:
		parsed = extract_json_object(content)
		if parsed == null:
			_handle_failure(job, Code.BAD_JSON, status, "content не содержит валидного JSON-объекта")
			return

	_settle(job, _make_result(Code.OK, status, content, parsed, "", job))


## [param server_hint_sec] — пауза, которую запросил сам сервер (0 = не запрашивал).
func _handle_failure(job: ApiJob, code: Code, status: int, detail: String, server_hint_sec: float = 0.0) -> void:
	var max_wait: float = maxf(1.0, GameConfig.get_float("api", "max_retry_wait_sec"))

	# Сервер просит паузу дольше допустимой — нет смысла жечь попытки и морозить
	# игру. Сразу отдаём отказ, режиссёр уйдёт на локальный генератор.
	if server_hint_sec > max_wait:
		Log.warn("Api", "Сервер просит слишком долгую паузу — ухожу в отказ без ретраев", {
			"job": job.id, "status": status,
			"просит_с": "%.0f" % server_hint_sec, "лимит_с": "%.0f" % max_wait,
		})
		_settle(job, _make_result(code, status, "", null,
			"%s (сервер требует паузу %.0f с, лимит %.0f с)" % [detail, server_hint_sec, max_wait], job))
		return

	if job.attempts >= job.max_attempts or job.cancelled:
		Log.error("Api", "Запрос окончательно провален", {
			"job": job.id, "код": CODE_NAMES[code], "status": status,
			"попыток": job.attempts, "деталь": detail,
		})
		_settle(job, _make_result(code, status, "", null, detail, job))
		return

	var delay: float = minf(MAX_BACKOFF_SEC, BASE_BACKOFF_SEC * pow(2.0, float(job.attempts - 1)))
	if server_hint_sec > 0.0:
		delay = maxf(delay, server_hint_sec + 0.5)
	delay += randf() * 0.6  # джиттер, чтобы параллельные джобы не били синхронно
	Log.warn("Api", "Повтор запроса", {
		"job": job.id, "код": CODE_NAMES[code], "status": status,
		"попытка": job.attempts, "пауза_с": "%.1f" % delay,
		"просил_сервер_с": "%.0f" % server_hint_sec, "деталь": detail,
	})
	job_retrying.emit(job.id, job.attempts, delay)

	var timer: SceneTreeTimer = get_tree().create_timer(delay, true, false, true)
	await timer.timeout

	if job.cancelled:
		_settle(job, _make_result(Code.CANCELLED, status, "", null, "отменён во время паузы", job))
		return
	_dispatch(job)


## Завершение джобы, стоявшей в _in_flight: освобождает слот и качает очередь.
func _settle(job: ApiJob, result: Dictionary) -> void:
	if _in_flight.has(job.id):
		_in_flight.erase(job.id)
		_active = maxi(0, _active - 1)
	_finish(job, result)
	_pump()


func _finish(job: ApiJob, result: Dictionary) -> void:
	if job.is_done():
		return
	job.result = result
	var ok: bool = bool(result.get("ok", false))
	job_finished.emit(job.id, ok, int(result.get("code", Code.OFFLINE)))
	if ok:
		Log.info("Api", "Запрос выполнен", {
			"job": job.id, "label": job.label,
			"мс": int(result.get("elapsed_ms", 0)), "попыток": int(result.get("attempts", 0)),
		})
	job.finished.emit(result)


func _cleanup_http(http: HTTPRequest) -> void:
	if http == null or not is_instance_valid(http):
		return
	http.cancel_request()
	http.queue_free()


func _make_result(code: Code, status: int, content: String, parsed: Variant, error: String, job: ApiJob) -> Dictionary:
	return {
		"ok": code == Code.OK,
		"code": int(code),
		"code_name": str(CODE_NAMES.get(code, "?")),
		"http_status": status,
		"content": content,
		"json": parsed,
		"error": error,
		"attempts": job.attempts,
		"job_id": job.id,
		"label": job.label,
		"elapsed_ms": Time.get_ticks_msec() - job.started_msec,
	}


# ---------------------------------------------------------------- разбор ответа

func _extract_content(envelope: Dictionary) -> String:
	var choices: Variant = envelope.get("choices", null)
	if not (choices is Array) or (choices as Array).is_empty():
		return ""
	var first: Variant = (choices as Array)[0]
	if not (first is Dictionary):
		return ""
	var message: Variant = (first as Dictionary).get("message", null)
	if not (message is Dictionary):
		return ""
	var content: Variant = (message as Dictionary).get("content", null)
	if content is String:
		return content as String
	# Некоторые шлюзы отдают content массивом частей.
	if content is Array:
		var joined: String = ""
		for part: Variant in content as Array:
			if part is Dictionary and (part as Dictionary).has("text"):
				joined += str((part as Dictionary)["text"])
			elif part is String:
				joined += part as String
		return joined
	return ""


## Сколько секунд просит подождать сервер. Смотрит заголовки Retry-After /
## x-ratelimit-*, а если их нет — вытаскивает число из текста ошибки
## («Please wait 45 seconds before retrying»). 0 = сервер ничего не просил.
func _retry_delay_hint(headers: PackedStringArray, detail: String) -> float:
	for header: String in headers:
		var separator: int = header.find(":")
		if separator < 0:
			continue
		var key: String = header.substr(0, separator).strip_edges().to_lower()
		var value: String = header.substr(separator + 1).strip_edges()
		if key in ["retry-after", "x-ratelimit-timeremaining", "x-ratelimit-reset-requests"]:
			if value.is_valid_float():
				return maxf(0.0, value.to_float())

	var regex := RegEx.new()
	if regex.compile("wait\\s+([0-9]+)\\s*second") != OK:
		return 0.0
	var found: RegExMatch = regex.search(detail.to_lower())
	if found == null:
		return 0.0
	var seconds: String = found.get_string(1)
	return maxf(0.0, seconds.to_float()) if seconds.is_valid_float() else 0.0


func _extract_api_error(raw: String) -> String:
	var parsed: Variant = JSON.parse_string(raw)
	if parsed is Dictionary:
		var err: Variant = (parsed as Dictionary).get("error", null)
		if err is Dictionary:
			return str((err as Dictionary).get("message", raw))
		if err is String:
			return err as String
	if raw.length() > 300:
		return raw.substr(0, 297) + "..."
	return raw


## Достаёт JSON-объект из произвольного текста модели.
## Снимает ```json-обёртки и ищет первый сбалансированный блок `{...}`,
## корректно пропуская скобки внутри строк и экранирование.
## Возвращает Dictionary или null.
static func extract_json_object(text: String) -> Variant:
	var cleaned: String = text.strip_edges()

	if cleaned.begins_with("```"):
		var fence_end: int = cleaned.find("\n")
		if fence_end >= 0:
			cleaned = cleaned.substr(fence_end + 1)
		var closing: int = cleaned.rfind("```")
		if closing >= 0:
			cleaned = cleaned.substr(0, closing)
		cleaned = cleaned.strip_edges()

	# Пробуем разобрать целиком только если строка вообще похожа на объект —
	# иначе JSON.parse_string зря сыпет push_error в консоль.
	if cleaned.begins_with("{") and cleaned.ends_with("}"):
		var direct: Variant = JSON.parse_string(cleaned)
		if direct is Dictionary:
			return direct

	var start: int = cleaned.find("{")
	while start >= 0:
		var depth: int = 0
		var in_string: bool = false
		var escaped: bool = false
		for i: int in range(start, cleaned.length()):
			var ch: String = cleaned[i]
			if escaped:
				escaped = false
				continue
			if ch == "\\":
				escaped = true
				continue
			if ch == "\"":
				in_string = not in_string
				continue
			if in_string:
				continue
			if ch == "{":
				depth += 1
			elif ch == "}":
				depth -= 1
				if depth == 0:
					var candidate: String = cleaned.substr(start, i - start + 1)
					var parsed: Variant = JSON.parse_string(candidate)
					if parsed is Dictionary:
						return parsed
					break
		start = cleaned.find("{", start + 1)

	return null
