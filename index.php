<?php
header("Cache-Control: no-store, no-cache, must-revalidate");
header("Pragma: no-cache");
header("X-GD-Served: php");

$html = file_get_contents(__DIR__ . "/index.htm");
if ($html === false) {
    http_response_code(500);
    echo "Missing index.htm";
    exit;
}

$stamp = gd_version_stamp();
header("X-GD-Version: " . ($stamp !== "" ? $stamp : "missing"));

if ($stamp !== "") {
    $safe = htmlspecialchars($stamp, ENT_QUOTES, "UTF-8");
    $replaced = preg_replace(
        '/(<span class="site-version"[^>]*>)(.*?)(<\/span>)/s',
        '${1}' . $safe . '${3}',
        $html,
        1
    );
    if (is_string($replaced)) {
        $html = $replaced;
    }
}

echo $html;

function gd_version_stamp() {
    $txtFile = __DIR__ . "/version.txt";
    if (is_readable($txtFile)) {
        $txt = trim((string) file_get_contents($txtFile));
        $txt = preg_replace('/^\xEF\xBB\xBF/', "", $txt);
        if (is_string($txt) && $txt !== "" && strpos($txt, "__SITE_VERSION__") === false) {
            return "v." . $txt;
        }
    }

    $jsonFile = __DIR__ . "/version.json";
    if (is_readable($jsonFile)) {
        $raw = (string) file_get_contents($jsonFile);
        $raw = preg_replace('/^\xEF\xBB\xBF/', "", $raw);
        $data = json_decode($raw, true);
        if (is_array($data)) {
            $ver = "";
            if (isset($data["version"]) && is_string($data["version"])) {
                $ver = $data["version"];
            }
            if ($ver !== "") {
                return "v." . $ver;
            }
        }
    }

    $jsFile = __DIR__ . "/version.js";
    if (is_readable($jsFile)) {
        $js = (string) file_get_contents($jsFile);
        if (preg_match('/textContent = "(v\.[^"]+)"/', $js, $m) === 1) {
            return $m[1];
        }
    }

    return "";
}
