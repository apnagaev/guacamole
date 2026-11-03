-- Раскладка клавиатуры для всех RDP-подключений (база guacamole).
-- failsafe («Unicode»): печатается то, что выбрано на компьютере пользователя, раскладка удалённой машины не важна.
--   Минусы: на экране входа Windows и в окнах UAC ввод может не работать, в части программ (игры, xrdp) бывают сбои.
-- ru-ru-qwerty («Russian (Qwerty)»): как физическая клавиатура, язык ввода выбирается на удалённой машине.
-- Применить: mysql -h <хост> -u guacamole -p guacamole < rdp-keyboard.sql   (перезапуск не нужен, действует на новые сеансы)
INSERT INTO guacamole_connection_parameter (connection_id, parameter_name, parameter_value)
SELECT connection_id, 'server-layout', 'failsafe'
FROM guacamole_connection WHERE protocol = 'rdp'
ON DUPLICATE KEY UPDATE parameter_value = VALUES(parameter_value);
