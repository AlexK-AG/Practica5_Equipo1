extends Node
## Autoload: perfiles locales, progreso, mejoras y opciones de audio.
signal settings_changed
signal display_preview_finished(confirmed: bool)
const DEFAULT_OPTIONS := {"fov": 78.0, "difficulty": 1, "fullscreen": false, "resolution": 0, "render_scale": 1.0, "brightness": 1.0, "reduced_motion": false, "reduced_flashes": false, "crosshair": true, "quality": 1}
const DISPLAY_KEYS := ["fullscreen", "resolution", "render_scale"]
const WINDOW_SIZES := [Vector2i(1280, 720), Vector2i(1600, 900), Vector2i(1920, 1080)]
const DEFAULT_SENSITIVITY := 0.0022
const DEFAULT_MUSIC_VOLUME := 0.45
const DEFAULT_EFFECTS_VOLUME := 0.7
const LEVELS := [
	{"title": "Laboratorio", "path": "res://scenes/main.tscn", "brief": "Restaura energía, consigue la tarjeta y asegura la extracción"},
	{"title": "Almacén", "path": "res://scenes/levels/level_2.tscn", "brief": "Transporta dos cargas, prepara el muelle y resiste dos oleadas"},
	{"title": "Reactor", "path": "res://scenes/levels/level_3.tscn", "brief": "Estabiliza el reactor, recupera la carga inicial y evacua en 180 segundos"},
	{"title": "Fundición", "path": "res://scenes/levels/level_4.tscn", "brief": "Apaga la fragua y desactiva el horno de emergencia en 120 segundos"},
	{"title": "Biocontención", "path": "res://scenes/levels/level_5.tscn", "brief": "Destruye tres nidos y resiste una purga de 90 segundos"},
	{"title": "Fortaleza", "path": "res://scenes/levels/level_6.tscn", "brief": "Desactiva defensas, recupera tres llaves de mando y elimina al capitán"},
	{"title": "Comunicaciones", "path": "res://scenes/levels/level_7.tscn", "brief": "Activa los enlaces y completa la transmisión"},
	{"title": "Hangar de evacuación", "path": "res://scenes/levels/level_8.tscn", "brief": "Prepara combustible y protege la carga durante 120 segundos"},
	{"title": "Arsenal orbital", "path": "res://scenes/levels/level_9.tscn", "brief": "Recupera tres núcleos, asegura el arsenal y transporta la carga"},
	{"title": "Núcleo Áureo", "path": "res://scenes/levels/level_10.tscn", "brief": "Desactiva la energía en cada fase del guardián"}
]
const UPGRADES := {
	"health": {"title": "Vitalidad", "text": "+25 de vida máxima por rango", "max": 3},
	"damage": {"title": "Munición potenciada", "text": "+4 daño · escopeta +1 por perdigón · precisión +8", "max": 3},
	"shield": {"title": "Escudo regenerable", "text": "+25 de escudo por rango; regenera tras 3,5 s", "max": 3},
	"rifle": {"title": "Especialista en fusil", "text": "+12 balas de reserva inicial para el fusil", "max": 1},
	"reload": {"title": "Recarga táctica", "text": "Reduce la recarga 0,2 s por rango", "max": 2},
	"regen": {"title": "Nanorreparación", "text": "+3 PV/s de regeneración por rango", "max": 2},
	"magazine": {"title": "Cargador ampliado", "text": "+4 balas · escopeta/precisión +1 · plasma +2", "max": 1},
	"armor": {"title": "Blindaje", "text": "Reduce el daño recibido un 8% por rango", "max": 1},
	"melee": {"title": "Cuchillo mejorado", "text": "F: 100 de daño · intervalo reducido a 0,65 s", "max": 1},
	"speed": {"title": "Movilidad", "text": "+8% de velocidad por rango", "max": 1}
}
const OFFERS := [
	["health", "rifle", "shield"], ["damage", "reload", "melee"],
	["health", "shield", "regen"], ["damage", "magazine", "armor"],
	["health", "reload", "speed"], ["damage", "shield", "regen"],
	["shield", "armor", "magazine"], ["melee", "regen", "speed"], ["reload", "shield", "armor"]
]
var profiles: Dictionary = {}
var active_id: String = ""
var sensitivity: float = 0.0022
var music_volume: float = 0.45
var effects_volume: float = 0.7
var save_error: String = ""
var music: AudioStreamPlayer
const DATABASE_PATH := "user://sector07.sqlite"
var save_path := DATABASE_PATH
var legacy_save_path := ""
var store = preload("res://scripts/persistence/campaign_store.gd").new()
var _blocked_database := ""
var _migration_source := ""
var _pending_history: Array[Dictionary] = []
var events = preload("res://scripts/persistence/game_events.gd").new()
const DEFAULT_KEYS := {"forward": KEY_W, "back": KEY_S, "left": KEY_A, "right": KEY_D, "jump": KEY_SPACE, "sprint": KEY_SHIFT, "reload": KEY_R, "melee": KEY_F, "pause": KEY_ESCAPE, "weapon_one": KEY_1, "weapon_two": KEY_2, "interact": KEY_E, "grenade": KEY_G, "grenade_cycle": KEY_Q}
var bindings: Dictionary = {}
var options: Dictionary = DEFAULT_OPTIONS.duplicate(true)
var _display_before: Dictionary = {}
var _window_before: Dictionary = {}
var _display_deadline: int = 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if "--campaign-test" in OS.get_cmdline_user_args():
		save_path = "res://.godot/campaign-tests.sqlite"
	load_data()
	if store.db != null and events.recover_interrupted(store):
		flush_events()
	apply_display()
	if AudioServer.get_bus_index("Effects") < 0:
		AudioServer.add_bus()
		AudioServer.set_bus_name(AudioServer.bus_count - 1, "Effects")
	music = AudioStreamPlayer.new()
	music.name = "BackgroundMusic"
	add_child(music)
	apply_audio()

func fresh_profile(display_name: String) -> Dictionary:
	return {"name": display_name, "completed": [], "scores": {}, "choices": {}, "pending": -1, "record": 0, "weapon_unlocks": [], "starting_rifle": false, "grenade_unlocks": [], "discovered_enemies": []}

func select_profile(display_name: String) -> bool:
	display_name = display_name.strip_edges()
	if display_name.is_empty() or display_name.length() > 20:
		return false
	for c in display_name:
		if c.unicode_at(0) < 32:
			return false
	var previous_active := active_id
	active_id = display_name.to_lower()
	var created := not profiles.has(active_id)
	if created:
		profiles[active_id] = fresh_profile(display_name)
	# The profile action is committed in the same transaction as the selection.
	_open_store()
	var event_id: String = events.profile_action(active_id,"profile_created" if created else "profile_selected")
	if save_data():
		return true
	events.cancel_profile_action(event_id)
	if created:
		profiles.erase(active_id)
	active_id = previous_active
	return false

func profile() -> Dictionary:
	return profiles.get(active_id, {})

func delete_profile(id: String) -> bool:
	if not profiles.has(id):
		save_error = "El perfil seleccionado ya no existe."
		return false
	var previous_profiles := profiles.duplicate(true)
	var previous_active := active_id
	profiles.erase(id)
	if active_id == id:
		active_id = ""
	if not save_data():
		profiles = previous_profiles
		active_id = previous_active
		return false
	return true

func discover_enemy(kind: int) -> bool:
	if profile().is_empty() or kind < 0 or kind >= preload("res://scripts/enemies/enemy_catalog.gd").ENTRIES.size():
		return false
	var discovered: Array = profile().get("discovered_enemies", []).duplicate()
	if discovered.has(kind):
		return false
	discovered.append(kind)
	discovered.sort()
	var previous: Array = profile().get("discovered_enemies", []).duplicate()
	profile()["discovered_enemies"] = discovered
	if save_data():
		return true
	profile()["discovered_enemies"] = previous
	return false

func available_weapons(level: int) -> Array[String]:
	var result: Array[String] = ["pistol"]
	for id in ["rifle", "shotgun", "precision", "plasma"]:
		if profile().get("weapon_unlocks", []).has(id):
			result.append(id)
	return result

func selected_loadout(level: int) -> Array[String]:
	var result: Array[String] = []
	var available := available_weapons(level)
	for id in profile().get("loadout", ["pistol", "rifle"]):
		if available.has(str(id)) and not result.has(str(id)):
			result.append(str(id))
	for id in available:
		if result.size() < 2 and not result.has(id):
			result.append(id)
	return result.slice(0, 2)

func unlocked(index: int) -> bool:
	if profile().is_empty() or index < 0 or index >= LEVELS.size():
		return false
	return index == 0 or profile().completed.has(index - 1)

func pending() -> int:
	return int(profile().get("pending", -1))

func total_score() -> int:
	var total := 0
	for value in profile().get("scores", {}).values():
		total += int(value)
	return total

func complete_level(index: int, score: int, found_weapons: Array = [], found_grenades: Array = []) -> bool:
	if not unlocked(index) or pending() >= 0:
		return false
	var previous := profile().duplicate(true)
	var data := profile()
	var key := str(index)
	var unlocked_guns: Array = data.get("weapon_unlocks", []).duplicate()
	for id in found_weapons:
		if preload("res://scripts/combat/weapon_catalog.gd").DATA.has(id) and int(preload("res://scripts/combat/weapon_catalog.gd").DATA[id].unlock) == index + 1 and not unlocked_guns.has(id):
			unlocked_guns.append(id)
	data.weapon_unlocks = unlocked_guns
	var grenade_unlocks: Array = data.get("grenade_unlocks", []).duplicate()
	for id in found_grenades:
		if preload("res://scripts/combat/grenade_catalog.gd").DATA.has(id) and int(preload("res://scripts/combat/grenade_catalog.gd").DATA[id].unlock) == index + 1 and not grenade_unlocks.has(id):
			grenade_unlocks.append(id)
	data.grenade_unlocks = grenade_unlocks
	data.erase("checkpoint")
	data.scores[key] = maxi(int(data.scores.get(key, 0)), maxi(score, 0))
	if not data.completed.has(index):
		data.completed.append(index)
		if index < LEVELS.size() - 1:
			data.pending = index
	data.record = maxi(int(data.record), total_score())
	if save_data():
		return true
	profiles[active_id] = previous
	return false

func rank_of(id: String) -> int:
	var count := 0
	for choice in profile().get("choices", {}).values():
		if choice == id:
			count += 1
	return count

func available_grenades() -> Array[String]:
	var result: Array[String] = ["basic"]
	for id in ["fragmentation", "slow"]:
		if profile().get("grenade_unlocks", []).has(id):
			result.append(id)
	return result

func choose_upgrade(id: String) -> bool:
	var stage := pending()
	if stage < 0 or stage >= OFFERS.size() or not offers_for_stage(stage).has(id):
		return false
	if rank_of(id) >= int(UPGRADES[id].max):
		return false
	var previous := profile().duplicate(true)
	var data := profile()
	data.choices[str(stage)] = id
	data.pending = -1
	var event_id: String = events.profile_action(active_id,"upgrade_chosen",{"stage":stage+1,"upgrade":id})
	if save_data():
		return true
	events.cancel_profile_action(event_id)
	profiles[active_id] = previous
	return false

func offers_for_stage(stage: int) -> Array[String]:
	var result: Array[String] = []
	for id in OFFERS[stage]:
		if rank_of(id) < int(UPGRADES[id].max):
			result.append(id)
	for id in UPGRADES:
		if result.size() < 3 and not result.has(id) and rank_of(id) < int(UPGRADES[id].max):
			result.append(id)
	return result

func reset_campaign() -> bool:
	if profile().is_empty():
		return false
	var old := profile()
	var fresh := fresh_profile(old.name)
	fresh.record = maxi(int(old.record), total_score())
	fresh.discovered_enemies = old.get("discovered_enemies", []).duplicate()
	fresh.starting_rifle = bool(old.get("starting_rifle", false))
	if fresh.starting_rifle:
		fresh.weapon_unlocks = ["rifle"]
	fresh.tutorial_completed = bool(old.get("tutorial_completed", false))
	profiles[active_id] = fresh
	var event_id: String = events.profile_action(active_id,"campaign_reset")
	if save_data():
		return true
	events.cancel_profile_action(event_id)
	profiles[active_id] = old
	return false

func database_path() -> String:
	return save_path.get_basename()+".sqlite" if save_path.get_extension() == "cfg" else save_path

func legacy_path() -> String:
	if not legacy_save_path.is_empty():
		return legacy_save_path
	if save_path == DATABASE_PATH:
		return "user://campaigns.cfg"
	return save_path if save_path.get_extension() == "cfg" else save_path.get_basename()+".cfg"

func _open_store() -> bool:
	var target := database_path()
	if _blocked_database == target:
		return false
	if store.path != target:
		_pending_history.clear()
	events.bind_database(target)
	if not store.open(target):
		save_error = store.error
		return false
	return true

func save_data() -> bool:
	if not _open_store():
		return false
	var stored_options := options.duplicate(true)
	# A profile save must not confirm temporary screen settings.
	for key in _display_before:
		stored_options[key] = _display_before[key]
	var settings := {"sensitivity":sensitivity,"music":music_volume,"effects":effects_volume,"options":stored_options,"bindings":bindings}
	if not store.save_snapshot(profiles,settings,active_id,_pending_history,_migration_source,events.batch()):
		save_error = "No se pudo guardar en SQLite. " + store.error
		return false
	_pending_history.clear()
	events.committed()
	save_error = ""
	return true

func load_data() -> void:
	_blocked_database = ""
	_migration_source = ""
	if not _open_store():
		_blocked_database = database_path()
		return
	if store.initialized():
		var snapshot: Dictionary = store.load_snapshot()
		if snapshot.is_empty():
			save_error = store.error
			_blocked_database = database_path()
			return
		profiles = snapshot.profiles
		active_id = str(snapshot.active_id)
		_apply_saved_settings(snapshot.settings)
		save_error = ""
		return
	var config := ConfigFile.new()
	var old_path := legacy_path()
	if FileAccess.file_exists(old_path) or FileAccess.file_exists(old_path+".bak"):
		var loaded := config.load(old_path)
		if loaded != OK:
			loaded = config.load(old_path+".bak")
		if loaded != OK or not config.get_value("campaign","profiles",{}) is Dictionary:
			save_error = "No se pudo leer el guardado anterior. Se conservó sin modificar."
			_blocked_database = database_path()
			return
		profiles = config.get_value("campaign","profiles",{})
		_migrate_profiles(int(config.get_value("campaign","version",1)))
		var settings := {}
		for key in ["sensitivity","music","effects","options","bindings"]:
			if config.has_section_key("settings",key):
				settings[key] = config.get_value("settings",key)
		_apply_saved_settings(settings)
		_migration_source = old_path
	if not profiles.has(active_id):
		active_id = ""
	if not save_data():
		_blocked_database = database_path()

func _migrate_profiles(version: int) -> void:
	if version < 4:
		for data in profiles.values():
			data.erase("checkpoint")
			data["loadout"] = ["pistol","rifle"]
			data["weapon_unlocks"] = []
	if version < 5:
		for data in profiles.values():
			var guns: Array = data.get("weapon_unlocks",[]).duplicate()
			if not guns.has("rifle"):
				guns.append("rifle")
			data["weapon_unlocks"] = guns
			data["starting_rifle"] = true

func _apply_saved_settings(settings: Dictionary) -> void:
	sensitivity = clampf(float(settings.get("sensitivity",0.0022)),0.0005,0.006)
	music_volume = clampf(float(settings.get("music",0.45)),0,1)
	effects_volume = clampf(float(settings.get("effects",0.7)),0,1)
	var saved_options: Variant = settings.get("options",{})
	if saved_options is Dictionary:
		for key in options:
			if saved_options.has(key) and typeof(saved_options[key]) == typeof(options[key]):
				options[key] = saved_options[key]
	options.fov = clampf(float(options.fov),65,105)
	options.difficulty = clampi(int(options.difficulty),0,2)
	options.resolution = clampi(int(options.resolution),0,2)
	options.quality = clampi(int(options.quality),0,2)
	options.render_scale = clampf(float(options.render_scale),0.5,1.0)
	options.brightness = clampf(float(options.brightness),0.75,1.35)
	var saved_bindings: Variant = settings.get("bindings",{})
	bindings.clear()
	if saved_bindings is Dictionary:
		for action in DEFAULT_KEYS:
			if action != "pause" and saved_bindings.get(action,0) is int and int(saved_bindings.get(action,0)) > 0:
				bindings[action] = saved_bindings[action]

func record_run(entry: Dictionary) -> bool:
	if not _open_store() or not profiles.has(str(entry.get("profile_id",""))):
		return false
	if int(entry.get("level",0)) not in range(1,11) or entry.get("outcome","") not in ["victory","defeat","abandoned"]:
		return false
	if not _pending_history.any(func(item):return item.id == entry.id):
		_pending_history.append(entry.duplicate(true))
	return save_data()

func apply_display() -> void:
	var viewport := get_tree().root
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	viewport.scaling_3d_scale = clampf(float(options.render_scale), 0.5, 1.0)
	if display_context() == "standalone":
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if options.fullscreen else DisplayServer.WINDOW_MODE_WINDOWED)
		if not options.fullscreen:
			var desired: Vector2i = WINDOW_SIZES[clampi(int(options.resolution), 0, 2)]
			var usable := DisplayServer.screen_get_usable_rect()
			if usable.size.x > 0 and usable.size.y > 0:
				desired = desired.min(usable.size - Vector2i(16, 48))
			DisplayServer.window_set_size(desired)
	apply_game_options()

func display_context() -> String:
	if DisplayServer.get_name() == "headless":
		return "headless"
	if Engine.has_method("is_embedded_in_editor") and bool(Engine.call("is_embedded_in_editor")):
		return "embedded"
	return "standalone"

func apply_game_options() -> void:
	var scene := get_tree().current_scene
	if is_instance_valid(scene) and scene.has_method("apply_visual_options"):
		scene.apply_visual_options()

func display_values() -> Dictionary:
	var result := {}
	for key in DISPLAY_KEYS:
		result[key] = options[key]
	return result

func screen_preview_active() -> bool:
	return not _display_before.is_empty()

func screen_preview_seconds() -> int:
	return maxi(0, ceili(float(_display_deadline - Time.get_ticks_msec()) / 1000.0)) if screen_preview_active() else 0

func preview_display(changes: Dictionary, seconds: float = 10.0) -> bool:
	if screen_preview_active():
		return false
	if display_context() == "embedded" and (changes.has("fullscreen") or changes.has("resolution")):
		save_error = "El tamaño y la pantalla completa los controla el editor en la vista incrustada."
		return false
	var proposed := display_values()
	for key in changes:
		if key in DISPLAY_KEYS:
			proposed[key] = changes[key]
	proposed.resolution = clampi(int(proposed.resolution), 0, 2)
	proposed.render_scale = clampf(float(proposed.render_scale), 0.5, 1.0)
	proposed.fullscreen = bool(proposed.fullscreen)
	if proposed == display_values():
		return false
	_display_before = display_values()
	_window_before = {}
	if display_context() == "standalone":
		_window_before = {"mode": DisplayServer.window_get_mode(), "size": DisplayServer.window_get_size(), "position": DisplayServer.window_get_position()}
	for key in DISPLAY_KEYS:
		options[key] = proposed[key]
	_display_deadline = Time.get_ticks_msec() + roundi(maxf(.05, seconds) * 1000)
	apply_display()
	return true

func confirm_display_preview() -> bool:
	if not screen_preview_active():
		return false
	var previous := _display_before.duplicate()
	_display_before.clear()
	if not save_data():
		_display_before = previous
		revert_display_preview()
		return false
	_window_before.clear()
	_display_deadline = 0
	settings_changed.emit()
	display_preview_finished.emit(true)
	return true

func revert_display_preview() -> void:
	if not screen_preview_active():
		return
	for key in _display_before:
		options[key] = _display_before[key]
	_display_before.clear()
	apply_display()
	if display_context() == "standalone" and not _window_before.is_empty():
		DisplayServer.window_set_mode(int(_window_before.mode))
		if int(_window_before.mode) == DisplayServer.WINDOW_MODE_WINDOWED:
			DisplayServer.window_set_size(_window_before.size)
			DisplayServer.window_set_position(_window_before.position)
	_window_before.clear()
	_display_deadline = 0
	settings_changed.emit()
	display_preview_finished.emit(false)

func _process(_delta: float) -> void:
	events.timer += _delta
	if events.timer >= events.FLUSH_SECONDS:
		if not _pending_history.is_empty():
			if not save_data():
				events.timer = 0
		else:
			flush_events()
	if screen_preview_active() and Time.get_ticks_msec() >= _display_deadline:
		revert_display_preview()

func reset_settings() -> bool:
	revert_display_preview()
	var previous := {"options": options.duplicate(true), "bindings": bindings.duplicate(), "sensitivity": sensitivity, "music": music_volume, "effects": effects_volume}
	var old_screen := display_values()
	options = DEFAULT_OPTIONS.duplicate(true)
	for key in DISPLAY_KEYS:
		options[key] = old_screen[key]
	bindings.clear()
	sensitivity = DEFAULT_SENSITIVITY
	music_volume = DEFAULT_MUSIC_VOLUME
	effects_volume = DEFAULT_EFFECTS_VOLUME
	var screen_defaults := {}
	for key in DISPLAY_KEYS:
		if key == "render_scale" or display_context() != "embedded":
			screen_defaults[key] = DEFAULT_OPTIONS[key]
	preview_display(screen_defaults)
	apply_audio()
	apply_game_options()
	if not save_data():
		revert_display_preview()
		options = previous.options
		bindings = previous.bindings
		sensitivity = previous.sensitivity
		music_volume = previous.music
		effects_volume = previous.effects
		apply_audio()
		apply_display()
		settings_changed.emit()
		return false
	settings_changed.emit()
	return true

func apply_audio() -> void:
	if is_instance_valid(music):
		music.volume_db = linear_to_db(maxf(0.0001, music_volume)) - 10
		music.stream_paused = music_volume <= 0
	var bus := AudioServer.get_bus_index("Effects")
	if bus >= 0:
		AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(0.0001, effects_volume)))
		AudioServer.set_bus_mute(bus, effects_volume <= 0)

func play_music(index: int) -> void:
	var names := ["01_laboratory", "02_warehouse", "03_reactor", "04_foundry", "05_biocontainment", "06_fortress", "07_communications", "08_hangar", "09_orbital_arsenal", "10_golden_core"]
	var path: String = "res://assets/audio/menu_tension.wav" if index < 0 else "res://assets/audio/levels/%s.wav" % names[clampi(index, 0, names.size() - 1)]
	var track := load(path) as AudioStreamWAV
	if track == null:
		push_warning("No se pudo cargar la música: " + path)
		return
	track.loop_mode = AudioStreamWAV.LOOP_FORWARD
	track.loop_begin = 0
	track.loop_end = int(track.get_length() * track.mix_rate)
	if music.stream != track:
		music.stop()
		music.stream = track
	if not music.playing:
		music.play()
	apply_audio()

func _exit_tree() -> void:
	if not _pending_history.is_empty() and not save_data():
		push_warning(save_error)
	flush_events()
	store.close()
	if is_instance_valid(music):
		music.stop()
		music.stream = null

func begin_events(id: String, profile_id: String, level: int, started: String, elapsed: float, resumed: bool) -> void:
	if not profiles.has(profile_id) or not _open_store():
		return
	if not events.recover_interrupted(store):
		push_warning("No se pudieron recuperar las sesiones interrumpidas: "+store.error)
	events.begin(id,profile_id,level,int(options.difficulty),started,elapsed,resumed)
	flush_events()

func flush_events() -> bool:
	if events.dirty.is_empty() and events.profile_pending.is_empty():
		events.timer = 0
		return true
	if store.db == null or store.path != database_path():
		return false
	if not store.save_telemetry(events.batch()):
		save_error = "Eventos pendientes de guardar: "+store.error
		# Keep the batch for retry, without attempting a write every frame.
		events.timer = 0
		push_warning(save_error)
		return false
	events.committed()
	return true
