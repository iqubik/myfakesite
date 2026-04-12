<?php
// file: status.php v1.0
header('Content-Type: application/json; charset=utf-8');
header('X-Powered-By: MySphere/VERSION_PLACEHOLDER');
http_response_code(200);

echo json_encode([
    'online' => true,
    'maintenance' => false,
    'version' => 'VERSION_PLACEHOLDER',
    'build' => '2026.03.15',
    'product' => 'MySphere',
    'api' => '1.0',
]);
