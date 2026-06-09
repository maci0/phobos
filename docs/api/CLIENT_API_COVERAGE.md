# Client API coverage matrix

Every Moonraker JSON-RPC method, cross-referenced across upstream Moonraker, phobos, and the reference clients (web UIs + touchscreens). Regenerate with `tools/client_api_scanner/` after bumping any source — the diff is the changelog.

- Moonraker: **120** · phobos: **144**
- fluidd (v1.37.1): **98** calls
- guppyscreen (git): **24** calls
- helixscreen (git): **53** calls
- klipperscreen (git): **36** calls
- mainsail (v2.13.2): **65** calls

## Client-called methods phobos does NOT register (9)

These are all **third-party Moonraker plugins or client-specific extensions**, absent from core Moonraker too — phobos returns `-32601` and the clients hide the feature, exactly as against a stock Moonraker without the plugin. Not phobos bugs.

- `machine.timelapse.get_settings` — wanted by fluidd, mainsail — `moonraker-timelapse` plugin (3rd-party)
- `machine.timelapse.lastframeinfo` — wanted by fluidd, helixscreen, mainsail — `moonraker-timelapse` plugin (3rd-party)
- `machine.timelapse.post_settings` — wanted by fluidd, mainsail — `moonraker-timelapse` plugin (3rd-party)
- `machine.timelapse.render` — wanted by fluidd, helixscreen, mainsail — `moonraker-timelapse` plugin (3rd-party)
- `machine.timelapse.saveframes` — wanted by fluidd, helixscreen, mainsail — `moonraker-timelapse` plugin (3rd-party)
- `server.files.get_file` — wanted by helixscreen — non-standard (not a core Moonraker JSON-RPC method; file download is HTTP)
- `server.helix.phase_tracking.status` — wanted by helixscreen — HelixScreen's own Moonraker plugin
- `server.helix.print_modified` — wanted by helixscreen — HelixScreen's own Moonraker plugin
- `server.helix.status` — wanted by helixscreen — HelixScreen's own Moonraker plugin

## Matrix

| Method | Moonraker | phobos | fluidd | guppyscreen | helixscreen | klipperscreen | mainsail |
|---|---|---|---|---|---|---|---|
| `access.delete_user` | · | ✅ | ✅ | · | · | · | · |
| `access.get_api_key` | ✅ | ✅ | ✅ | · | · | · | · |
| `access.get_user` | · | ✅ | ✅ | · | · | · | · |
| `access.info` | ✅ | ✅ | ✅ | · | · | · | · |
| `access.login` | ✅ | ✅ | ✅ | · | · | · | · |
| `access.logout` | ✅ | ✅ | ✅ | · | · | · | · |
| `access.oneshot_token` | ✅ | ✅ | ✅ | · | · | · | · |
| `access.post_api_key` | ✅ | ✅ | ✅ | · | · | · | · |
| `access.post_user` | · | ✅ | ✅ | · | · | · | · |
| `access.refresh_jwt` | ✅ | ✅ | ✅ | · | · | · | · |
| `access.user` | ✅ | · | · | · | · | · | · |
| `access.user.password` | ✅ | ✅ | ✅ | · | · | · | · |
| `access.users.list` | ✅ | ✅ | ✅ | · | · | · | · |
| `connection.register_remote_method` | ✅ | ✅ | · | · | · | · | · |
| `connection.send_event` | ✅ | ✅ | · | · | · | · | · |
| `debug.database.delete_item` | · | ✅ | · | · | · | · | · |
| `debug.database.get_item` | · | ✅ | · | · | · | · | · |
| `debug.database.item` | ✅ | · | · | · | · | · | · |
| `debug.database.list` | ✅ | ✅ | · | · | · | · | · |
| `debug.database.post_item` | · | ✅ | · | · | · | · | · |
| `debug.database.table` | ✅ | ✅ | · | · | · | · | · |
| `debug.notifiers.test` | ✅ | ✅ | · | · | · | · | · |
| `machine.device_power.devices` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `machine.device_power.get_device` | ✅ | ✅ | · | · | · | · | · |
| `machine.device_power.off` | ✅ | ✅ | · | · | · | ✅ | · |
| `machine.device_power.on` | ✅ | ✅ | · | · | · | ✅ | · |
| `machine.device_power.post_device` | ✅ | ✅ | ✅ | ✅ | · | · | ✅ |
| `machine.device_power.status` | ✅ | ✅ | ✅ | ✅ | · | · | · |
| `machine.peripherals.canbus` | ✅ | ✅ | ✅ | · | · | · | · |
| `machine.peripherals.serial` | ✅ | ✅ | ✅ | · | · | · | · |
| `machine.peripherals.usb` | ✅ | ✅ | ✅ | · | · | · | · |
| `machine.peripherals.video` | ✅ | ✅ | ✅ | · | · | · | · |
| `machine.proc_stats` | ✅ | ✅ | ✅ | · | · | · | ✅ |
| `machine.reboot` | ✅ | ✅ | ✅ | · | ✅ | ✅ | ✅ |
| `machine.services.restart` | ✅ | ✅ | ✅ | · | ✅ | ✅ | ✅ |
| `machine.services.start` | ✅ | ✅ | ✅ | · | · | · | ✅ |
| `machine.services.stop` | ✅ | ✅ | ✅ | · | · | · | ✅ |
| `machine.shutdown` | ✅ | ✅ | ✅ | · | ✅ | ✅ | ✅ |
| `machine.sudo.info` | ✅ | ✅ | · | · | · | · | · |
| `machine.sudo.password` | ✅ | ✅ | · | · | · | · | · |
| `machine.system_info` | ✅ | ✅ | ✅ | · | ✅ | ✅ | ✅ |
| `machine.td1.data` | ✅ | ✅ | · | · | · | · | · |
| `machine.td1.reboot` | ✅ | ✅ | · | · | · | · | · |
| `machine.timelapse.get_settings` | · | · | ✅ | · | · | · | ✅ |
| `machine.timelapse.lastframeinfo` | · | · | ✅ | · | ✅ | · | ✅ |
| `machine.timelapse.post_settings` | · | · | ✅ | · | · | · | ✅ |
| `machine.timelapse.render` | · | · | ✅ | · | ✅ | · | ✅ |
| `machine.timelapse.saveframes` | · | · | ✅ | · | ✅ | · | ✅ |
| `machine.update.client` | ✅ | ✅ | ✅ | · | · | ✅ | ✅ |
| `machine.update.full` | ✅ | ✅ | ✅ | · | · | · | ✅ |
| `machine.update.klipper` | ✅ | ✅ | ✅ | · | · | · | · |
| `machine.update.moonraker` | ✅ | ✅ | ✅ | · | · | · | · |
| `machine.update.recover` | ✅ | ✅ | ✅ | · | · | ✅ | ✅ |
| `machine.update.refresh` | ✅ | ✅ | ✅ | · | · | ✅ | · |
| `machine.update.rollback` | ✅ | ✅ | · | · | · | · | · |
| `machine.update.status` | ✅ | ✅ | ✅ | · | · | ✅ | ✅ |
| `machine.update.system` | ✅ | ✅ | ✅ | · | · | · | ✅ |
| `machine.update.upgrade` | ✅ | ✅ | · | · | · | · | · |
| `machine.wled.get_strip` | ✅ | ✅ | · | · | · | · | · |
| `machine.wled.off` | ✅ | ✅ | · | · | · | · | · |
| `machine.wled.on` | ✅ | ✅ | · | · | · | · | · |
| `machine.wled.post_strip` | ✅ | ✅ | · | · | · | · | · |
| `machine.wled.status` | ✅ | ✅ | · | · | · | · | · |
| `machine.wled.strips` | ✅ | ✅ | · | · | · | · | · |
| `machine.wled.toggle` | ✅ | ✅ | · | · | · | · | · |
| `pause_job_queue` | · | ✅ | · | · | · | · | · |
| `printer.emergency_stop` | · | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `printer.firmware_restart` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `printer.gcode.help` | · | ✅ | ✅ | ✅ | · | ✅ | · |
| `printer.gcode.script` | · | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `printer.info` | · | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `printer.objects.list` | · | ✅ | ✅ | ✅ | ✅ | ✅ | · |
| `printer.objects.query` | · | ✅ | · | · | ✅ | ✅ | · |
| `printer.objects.subscribe` | · | ✅ | ✅ | ✅ | ✅ | ✅ | · |
| `printer.print.cancel` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `printer.print.pause` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `printer.print.resume` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `printer.print.start` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `printer.query_endstops.status` | · | ✅ | ✅ | · | · | ✅ | ✅ |
| `printer.restart` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `server.analysis.dump_config` | ✅ | ✅ | · | · | · | · | · |
| `server.analysis.estimate` | ✅ | ✅ | ✅ | · | · | · | · |
| `server.analysis.process` | ✅ | ✅ | ✅ | · | · | · | · |
| `server.analysis.status` | ✅ | ✅ | ✅ | · | · | · | · |
| `server.announcements.delete_feed` | ✅ | ✅ | · | · | · | · | · |
| `server.announcements.dismiss` | ✅ | ✅ | ✅ | · | · | · | ✅ |
| `server.announcements.feeds` | ✅ | ✅ | · | · | · | · | · |
| `server.announcements.list` | ✅ | ✅ | ✅ | · | · | · | ✅ |
| `server.announcements.post_feed` | ✅ | ✅ | · | · | · | · | · |
| `server.announcements.update` | ✅ | ✅ | · | · | · | · | · |
| `server.config` | ✅ | ✅ | ✅ | · | · | ✅ | ✅ |
| `server.connection.identify` | ✅ | ✅ | ✅ | · | ✅ | ✅ | · |
| `server.database.compact` | ✅ | ✅ | ✅ | · | · | · | · |
| `server.database.delete_backup` | ✅ | ✅ | ✅ | · | · | · | · |
| `server.database.delete_item` | · | ✅ | ✅ | · | ✅ | · | ✅ |
| `server.database.get_item` | · | ✅ | ✅ | ✅ | ✅ | · | ✅ |
| `server.database.item` | ✅ | · | · | · | · | · | · |
| `server.database.list` | ✅ | ✅ | ✅ | · | · | · | ✅ |
| `server.database.post_backup` | ✅ | ✅ | ✅ | · | · | · | · |
| `server.database.post_item` | · | ✅ | ✅ | ✅ | ✅ | · | ✅ |
| `server.database.restore` | ✅ | ✅ | ✅ | · | · | · | · |
| `server.extensions.list` | ✅ | ✅ | · | · | · | · | · |
| `server.extensions.request` | ✅ | ✅ | · | · | · | · | · |
| `server.files.copy` | ✅ | ✅ | ✅ | · | ✅ | · | ✅ |
| `server.files.delete_directory` | · | ✅ | ✅ | · | ✅ | · | ✅ |
| `server.files.delete_file` | ✅ | ✅ | ✅ | · | ✅ | · | ✅ |
| `server.files.directory` | ✅ | · | · | · | · | · | · |
| `server.files.get_directory` | · | ✅ | ✅ | · | ✅ | ✅ | ✅ |
| `server.files.get_file` | · | · | · | · | ✅ | · | · |
| `server.files.list` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | · |
| `server.files.metadata` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `server.files.metascan` | ✅ | ✅ | ✅ | · | ✅ | · | ✅ |
| `server.files.move` | ✅ | ✅ | ✅ | · | ✅ | ✅ | ✅ |
| `server.files.post_directory` | · | ✅ | ✅ | · | ✅ | · | ✅ |
| `server.files.roots` | ✅ | ✅ | · | ✅ | · | · | · |
| `server.files.thumbnails` | ✅ | ✅ | · | · | · | · | · |
| `server.files.zip` | ✅ | ✅ | ✅ | · | · | · | ✅ |
| `server.gcode_store` | ✅ | ✅ | ✅ | · | ✅ | ✅ | ✅ |
| `server.helix.phase_tracking.status` | · | · | · | · | ✅ | · | · |
| `server.helix.print_modified` | · | · | · | · | ✅ | · | · |
| `server.helix.status` | · | · | · | · | ✅ | · | · |
| `server.history.delete_job` | ✅ | ✅ | ✅ | · | ✅ | · | ✅ |
| `server.history.get_job` | ✅ | ✅ | · | · | · | ✅ | · |
| `server.history.list` | ✅ | ✅ | ✅ | · | ✅ | · | ✅ |
| `server.history.reset_totals` | ✅ | ✅ | ✅ | · | · | · | · |
| `server.history.totals` | ✅ | ✅ | ✅ | · | ✅ | · | ✅ |
| `server.info` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `server.job_queue.delete_job` | ✅ | ✅ | ✅ | · | ✅ | · | ✅ |
| `server.job_queue.jump` | ✅ | ✅ | · | · | · | · | · |
| `server.job_queue.pause` | ✅ | ✅ | ✅ | · | ✅ | · | ✅ |
| `server.job_queue.post_job` | ✅ | ✅ | ✅ | · | ✅ | · | ✅ |
| `server.job_queue.start` | ✅ | ✅ | ✅ | · | ✅ | · | ✅ |
| `server.job_queue.status` | ✅ | ✅ | ✅ | · | ✅ | · | ✅ |
| `server.logs.rollover` | ✅ | ✅ | ✅ | · | · | · | ✅ |
| `server.mqtt.publish` | ✅ | ✅ | · | · | · | · | · |
| `server.mqtt.publish_mqtt_topic` | · | ✅ | · | · | · | · | · |
| `server.mqtt.subscribe` | ✅ | ✅ | · | · | · | · | · |
| `server.notifiers.list` | ✅ | ✅ | · | · | · | · | · |
| `server.restart` | ✅ | ✅ | ✅ | · | ✅ | · | ✅ |
| `server.sensors.info` | ✅ | ✅ | · | · | · | · | · |
| `server.sensors.list` | ✅ | ✅ | ✅ | · | ✅ | · | ✅ |
| `server.sensors.measurements` | ✅ | ✅ | · | · | · | · | · |
| `server.spoolman.get_spool_id` | ✅ | ✅ | ✅ | ✅ | · | · | ✅ |
| `server.spoolman.post_spool_id` | ✅ | ✅ | ✅ | ✅ | ✅ | · | ✅ |
| `server.spoolman.proxy` | ✅ | ✅ | ✅ | ✅ | ✅ | · | ✅ |
| `server.spoolman.status` | ✅ | ✅ | · | · | ✅ | · | · |
| `server.temperature_store` | ✅ | ✅ | ✅ | · | · | ✅ | ✅ |
| `server.webcams.delete_item` | · | ✅ | ✅ | · | · | · | ✅ |
| `server.webcams.get_item` | · | ✅ | · | · | · | · | · |
| `server.webcams.item` | ✅ | · | · | · | · | · | · |
| `server.webcams.list` | ✅ | ✅ | ✅ | · | ✅ | ✅ | ✅ |
| `server.webcams.post_item` | · | ✅ | ✅ | · | · | · | ✅ |
| `server.webcams.test` | ✅ | ✅ | · | · | · | · | · |
| `server.websocket.id` | ✅ | ✅ | · | · | · | · | · |
| `set_wled` | · | ✅ | · | · | · | · | · |
| `set_wled_state` | · | ✅ | · | · | · | · | · |
| `spoolman_set_active_spool` | · | ✅ | · | · | · | · | · |
| `start_job_queue` | · | ✅ | · | · | · | · | · |
