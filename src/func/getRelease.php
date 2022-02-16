<?php
function getRelease($slug)
{
    global $config;
    $cacheFile = $config['cache_path'] . '/' . md5($slug);
    if (!is_file($cacheFile)) {
        touch($cacheFile, 0);
    }
    if (filemtime($cacheFile) + $config['cache_lifetime_sec'] < time()) {
        unlink($cacheFile);
    }
    if (is_file($cacheFile)) {
        return json_decode(file_get_contents($cacheFile));
    }
    $opts = [
        'http' => [
            'method' => 'GET',
            'header' => "User-Agent: GHRI 0.1.1\r\n",
        ],
    ];
    $context = stream_context_create($opts);
    $data = file_get_contents(
        "https://api.github.com/repos/$slug/releases/latest",
        false,
        $context
    );
    file_put_contents($cacheFile, $data);
    return json_decode($data);
}
