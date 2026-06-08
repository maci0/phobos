# Client API coverage matrix

Every JSON-RPC method, cross-referenced across upstream Moonraker, phobos, and the two reference web UIs (Fluidd, Mainsail). Regenerate with `tools/client_api_scanner/` after bumping any source; the diff is the changelog.

- Moonraker: **120** · phobos: **144** · Fluidd calls: **98** · Mainsail calls: **65**


## ⚠ UI-called methods phobos does NOT register (5)

- `machine.timelapse.get_settings`
- `machine.timelapse.lastframeinfo`
- `machine.timelapse.post_settings`
- `machine.timelapse.render`
- `machine.timelapse.saveframes`


## Matrix

| Method | Moonraker | phobos | Fluidd | Mainsail |
|---|---|---|---|---|
| `access.delete_user` | — | yes | yes | — |
| `access.get_api_key` | yes | yes | yes | — |
| `access.get_user` | — | yes | yes | — |
| `access.info` | yes | yes | yes | — |
| `access.login` | yes | yes | yes | — |
| `access.logout` | yes | yes | yes | — |
| `access.oneshot_token` | yes | yes | yes | — |
| `access.post_api_key` | yes | yes | yes | — |
| `access.post_user` | — | yes | yes | — |
| `access.refresh_jwt` | yes | yes | yes | — |
| `access.user` | yes | — | — | — |
| `access.user.password` | yes | yes | yes | — |
| `access.users.list` | yes | yes | yes | — |
| `connection.register_remote_method` | yes | yes | — | — |
| `connection.send_event` | yes | yes | — | — |
| `debug.database.delete_item` | — | yes | — | — |
| `debug.database.get_item` | — | yes | — | — |
| `debug.database.item` | yes | — | — | — |
| `debug.database.list` | yes | yes | — | — |
| `debug.database.post_item` | — | yes | — | — |
| `debug.database.table` | yes | yes | — | — |
| `debug.notifiers.test` | yes | yes | — | — |
| `machine.device_power.devices` | yes | yes | yes | yes |
| `machine.device_power.get_device` | yes | yes | — | — |
| `machine.device_power.off` | yes | yes | — | — |
| `machine.device_power.on` | yes | yes | — | — |
| `machine.device_power.post_device` | yes | yes | yes | yes |
| `machine.device_power.status` | yes | yes | yes | — |
| `machine.peripherals.canbus` | yes | yes | yes | — |
| `machine.peripherals.serial` | yes | yes | yes | — |
| `machine.peripherals.usb` | yes | yes | yes | — |
| `machine.peripherals.video` | yes | yes | yes | — |
| `machine.proc_stats` | yes | yes | yes | yes |
| `machine.reboot` | yes | yes | yes | yes |
| `machine.services.restart` | yes | yes | yes | yes |
| `machine.services.start` | yes | yes | yes | yes |
| `machine.services.stop` | yes | yes | yes | yes |
| `machine.shutdown` | yes | yes | yes | yes |
| `machine.sudo.info` | yes | yes | — | — |
| `machine.sudo.password` | yes | yes | — | — |
| `machine.system_info` | yes | yes | yes | yes |
| `machine.td1.data` | yes | yes | — | — |
| `machine.td1.reboot` | yes | yes | — | — |
| `machine.timelapse.get_settings` | — | — | yes | yes |
| `machine.timelapse.lastframeinfo` | — | — | yes | yes |
| `machine.timelapse.post_settings` | — | — | yes | yes |
| `machine.timelapse.render` | — | — | yes | yes |
| `machine.timelapse.saveframes` | — | — | yes | yes |
| `machine.update.client` | yes | yes | yes | yes |
| `machine.update.full` | yes | yes | yes | yes |
| `machine.update.klipper` | yes | yes | yes | — |
| `machine.update.moonraker` | yes | yes | yes | — |
| `machine.update.recover` | yes | yes | yes | yes |
| `machine.update.refresh` | yes | yes | yes | — |
| `machine.update.rollback` | yes | yes | — | — |
| `machine.update.status` | yes | yes | yes | yes |
| `machine.update.system` | yes | yes | yes | yes |
| `machine.update.upgrade` | yes | yes | — | — |
| `machine.wled.get_strip` | yes | yes | — | — |
| `machine.wled.off` | yes | yes | — | — |
| `machine.wled.on` | yes | yes | — | — |
| `machine.wled.post_strip` | yes | yes | — | — |
| `machine.wled.status` | yes | yes | — | — |
| `machine.wled.strips` | yes | yes | — | — |
| `machine.wled.toggle` | yes | yes | — | — |
| `pause_job_queue` | — | yes | — | — |
| `printer.emergency_stop` | — | yes | yes | yes |
| `printer.firmware_restart` | yes | yes | yes | yes |
| `printer.gcode.help` | — | yes | yes | — |
| `printer.gcode.script` | — | yes | yes | yes |
| `printer.info` | — | yes | yes | yes |
| `printer.objects.list` | — | yes | yes | — |
| `printer.objects.query` | — | yes | — | — |
| `printer.objects.subscribe` | — | yes | yes | — |
| `printer.print.cancel` | yes | yes | yes | yes |
| `printer.print.pause` | yes | yes | yes | yes |
| `printer.print.resume` | yes | yes | yes | yes |
| `printer.print.start` | yes | yes | yes | yes |
| `printer.query_endstops.status` | — | yes | yes | yes |
| `printer.restart` | yes | yes | yes | yes |
| `server.analysis.dump_config` | yes | yes | — | — |
| `server.analysis.estimate` | yes | yes | yes | — |
| `server.analysis.process` | yes | yes | yes | — |
| `server.analysis.status` | yes | yes | yes | — |
| `server.announcements.delete_feed` | yes | yes | — | — |
| `server.announcements.dismiss` | yes | yes | yes | yes |
| `server.announcements.feeds` | yes | yes | — | — |
| `server.announcements.list` | yes | yes | yes | yes |
| `server.announcements.post_feed` | yes | yes | — | — |
| `server.announcements.update` | yes | yes | — | — |
| `server.config` | yes | yes | yes | yes |
| `server.connection.identify` | yes | yes | yes | — |
| `server.database.compact` | yes | yes | yes | — |
| `server.database.delete_backup` | yes | yes | yes | — |
| `server.database.delete_item` | — | yes | yes | yes |
| `server.database.get_item` | — | yes | yes | yes |
| `server.database.item` | yes | — | — | — |
| `server.database.list` | yes | yes | yes | yes |
| `server.database.post_backup` | yes | yes | yes | — |
| `server.database.post_item` | — | yes | yes | yes |
| `server.database.restore` | yes | yes | yes | — |
| `server.extensions.list` | yes | yes | — | — |
| `server.extensions.request` | yes | yes | — | — |
| `server.files.copy` | yes | yes | yes | yes |
| `server.files.delete_directory` | — | yes | yes | yes |
| `server.files.delete_file` | yes | yes | yes | yes |
| `server.files.directory` | yes | — | — | — |
| `server.files.get_directory` | — | yes | yes | yes |
| `server.files.list` | yes | yes | yes | — |
| `server.files.metadata` | yes | yes | yes | yes |
| `server.files.metascan` | yes | yes | yes | yes |
| `server.files.move` | yes | yes | yes | yes |
| `server.files.post_directory` | — | yes | yes | yes |
| `server.files.roots` | yes | yes | — | — |
| `server.files.thumbnails` | yes | yes | — | — |
| `server.files.zip` | yes | yes | yes | yes |
| `server.gcode_store` | yes | yes | yes | yes |
| `server.history.delete_job` | yes | yes | yes | yes |
| `server.history.get_job` | yes | yes | — | — |
| `server.history.list` | yes | yes | yes | yes |
| `server.history.reset_totals` | yes | yes | yes | — |
| `server.history.totals` | yes | yes | yes | yes |
| `server.info` | yes | yes | yes | yes |
| `server.job_queue.delete_job` | yes | yes | yes | yes |
| `server.job_queue.jump` | yes | yes | — | — |
| `server.job_queue.pause` | yes | yes | yes | yes |
| `server.job_queue.post_job` | yes | yes | yes | yes |
| `server.job_queue.start` | yes | yes | yes | yes |
| `server.job_queue.status` | yes | yes | yes | yes |
| `server.logs.rollover` | yes | yes | yes | yes |
| `server.mqtt.publish` | yes | yes | — | — |
| `server.mqtt.publish_mqtt_topic` | — | yes | — | — |
| `server.mqtt.subscribe` | yes | yes | — | — |
| `server.notifiers.list` | yes | yes | — | — |
| `server.restart` | yes | yes | yes | yes |
| `server.sensors.info` | yes | yes | — | — |
| `server.sensors.list` | yes | yes | yes | yes |
| `server.sensors.measurements` | yes | yes | — | — |
| `server.spoolman.get_spool_id` | yes | yes | yes | yes |
| `server.spoolman.post_spool_id` | yes | yes | yes | yes |
| `server.spoolman.proxy` | yes | yes | yes | yes |
| `server.spoolman.status` | yes | yes | — | — |
| `server.temperature_store` | yes | yes | yes | yes |
| `server.webcams.delete_item` | — | yes | yes | yes |
| `server.webcams.get_item` | — | yes | — | — |
| `server.webcams.item` | yes | — | — | — |
| `server.webcams.list` | yes | yes | yes | yes |
| `server.webcams.post_item` | — | yes | yes | yes |
| `server.webcams.test` | yes | yes | — | — |
| `server.websocket.id` | yes | yes | — | — |
| `set_wled` | — | yes | — | — |
| `set_wled_state` | — | yes | — | — |
| `spoolman_set_active_spool` | — | yes | — | — |
| `start_job_queue` | — | yes | — | — |
