<?php
// file: phpinfo.php v1.1
// Ограниченный вывод: только общая информация и конфиг
// Без переменных окружения, $_SERVER, $_GET и других чувствительных данных
phpinfo(INFO_GENERAL | INFO_CONFIGURATION | INFO_MODULES);
