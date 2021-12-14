#!/usr/bin/env php
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
        "http" => [
            "method" => "GET",
            "header" =>
                "User-Agent: GHRI 0.1.1\r\n"
        ]
    ];
    $context = stream_context_create($opts);
    $data = file_get_contents("https://api.github.com/repos/$slug/releases/latest", false, $context);
    file_put_contents($cacheFile, $data);
    return json_decode($data);
}

function ensureDir($dir)
{
    if (is_dir($dir)) return true;
    mkdir($dir, 0777, true);
    if (is_dir($dir)) return true;
    echo "can't create dir $dir";
    die(1);
}


function PP_make_executeable($asset)
{
    chmod($asset->name, 0755);
}

function PP_link($asset, $pp, $package, $config)
{
    $link = $config['symlink_path'] . '/' . $package['name'];
    if (is_link($link)) {
        unlink($link);
    }
    symlink(realpath($asset->name), $link);
}

function PP_testrun($asset, $pp, $package, $config)
{
    $pp['quiet'] = (bool)(isset($pp['quiet']) ? $pp['quiet'] : false);
    @$command = (array)$pp['args'];
    array_unshift($command, $config['symlink_path'] . "/" . $package['name']);
    array_walk($command, function (&$v) {
        $v = escapeshellarg($v);
    });
    $command = "2>&1 " . implode(" ", $command);
    ob_start();
    system($command, $retval);
    if (0 !== $retval) {
        echo "error running $command, status code is $retval\n";
        die(1);
    }
    if ($pp['quiet']) ob_clean();
    return ob_get_clean();

}

function PP_unzip(&$asset, $pp)
{
    $pp['asset_matcher'] = isset($pp['asset_matcher']) ? $pp['asset_matcher'] : "/.*/";
    ob_start();
    system("2>&1 unzip -qq -u " . escapeshellarg($asset->name), $retval);
    $fp = popen("find . -type f -not -name " . escapeshellarg($asset->name), 'r');

    if (0 !== $retval) {
        echo "error running unzip, status code is $retval\n";
        die(1);
    }
    $newPossibleAssets = [];
    while ($fp && !feof($fp)) {
        $possibleAsset = substr(fgets($fp, 1024), 2, -1); // 2 removes ./ -1 removes newline
        if (!strlen($possibleAsset)) continue;
        $matcher = matcherPreparer($pp['asset_matcher']);
        if (!$matcher($possibleAsset)) continue;
        $newPossibleAssets[] = $possibleAsset;
    }
    if (1 == count($newPossibleAssets)) {
        $asset->name = array_shift($newPossibleAssets);
        return ob_get_clean();
    }
    if (count($newPossibleAssets)) {
        echo "    there are multiple matching assets: " . implode(", ", $newPossibleAssets), "\n";
    } else {
        echo "    no matching asset found\n";
    }
    die(1);
}

function PP_tar(&$asset, $pp)
{
    $pp['asset_matcher'] = isset($pp['asset_matcher']) ? $pp['asset_matcher'] : "/.*/";
    ob_start();
    system("2>&1 tar -xf " . escapeshellarg($asset->name), $retval);
    $fp = popen("find . -type f -not -name " . escapeshellarg($asset->name), 'r');

    if (0 !== $retval) {
        echo "error running unzip, status code is $retval\n";
        die(1);
    }
    $newPossibleAssets = [];
    while ($fp && !feof($fp)) {
        $possibleAsset = substr(fgets($fp, 1024), 2, -1); // 2 removes ./ -1 removes newline
        if (!strlen($possibleAsset)) continue;
        $matcher = matcherPreparer($pp['asset_matcher']);
        if (!$matcher($possibleAsset)) continue;
        $newPossibleAssets[] = $possibleAsset;
    }
    if (1 == count($newPossibleAssets)) {
        $asset->name = array_shift($newPossibleAssets);
        return ob_get_clean();
    }
    if (count($newPossibleAssets)) {
        echo "    there are multiple matching assets: " . implode(", ", $newPossibleAssets), "\n";
    } else {
        echo "    no matching asset found\n";
    }
    die(1);
}

function PP_xz(&$asset, $pp)
{
    $pp['asset_matcher'] = isset($pp['asset_matcher']) ? $pp['asset_matcher'] : "/.*/";
    ob_start();
    system("2>&1 xz -d --force " . escapeshellarg($asset->name), $retval);
    $fp = popen("find . -type f -not -name " . escapeshellarg($asset->name), 'r');

    if (0 !== $retval) {
        echo "error running unzip, status code is $retval\n";
        die(1);
    }
    $newPossibleAssets = [];
    while ($fp && !feof($fp)) {
        $possibleAsset = substr(fgets($fp, 1024), 2, -1); // 2 removes ./ -1 removes newline
        if (!strlen($possibleAsset)) continue;
        $matcher = matcherPreparer($pp['asset_matcher']);
        if (!$matcher($possibleAsset)) continue;
        $newPossibleAssets[] = $possibleAsset;
    }
    if (1 == count($newPossibleAssets)) {
        $asset->name = array_shift($newPossibleAssets);
        return ob_get_clean();
    }
    if (count($newPossibleAssets)) {
        echo "    there are multiple matching assets: " . implode(", ", $newPossibleAssets), "\n";
    } else {
        echo "    no matching asset found\n";
    }
    die(1);
}

function PP_bz2(&$asset)
{
    ob_start();
    system("2>&1 bunzip2 -k -f " . escapeshellarg($asset->name), $retval);
    $asset->name = basename($asset->name, ".bz2");
    if (0 !== $retval) {
        echo "error running bunzip2, status code is $retval\n";
        die(1);
    }
    return ob_get_clean();
}

function PP_gunzip(&$asset)
{
    ob_start();
    system("2>&1 gunzip -f -k " . escapeshellarg($asset->name), $retval);
    $asset->name = basename($asset->name, ".gz");
    if (0 !== $retval) {
        echo "error running bunzip2, status code is $retval\n";
        die(1);
    }
    return ob_get_clean();
}




function matcherPreparer($matcher)
{
    if (preg_match("/^\/.*\/[a-zA-Z]*$/", $matcher)) {
        // this is a regex_matcher
        return function ($string) use ($matcher) {
            return preg_match($matcher, $string);
        };
    }
    //the only other option is a glob matcher
    return function ($string) use ($matcher) {
        return fnmatch($matcher, $string);
    };

}


chdir(__DIR__);
$config = yaml_parse_file('config.yaml');
if (!$config) die(1);


foreach ($config as $k => $v) {
    if (!preg_match("/_path$/", $k)) continue;
    ensureDir($v);
    $config[$k] = realpath($v);

}


foreach ($config['packages'] as $package) {
    $package['name'] = isset($package['name']) ? $package['name'] : explode("/", $package['slug'])[1];
    $package['post_process'] = $package['post_process'] ?: [];
    if ($_SERVER['argc'] === 2 && $package['name'] !== $_SERVER['argv'][1]) continue;
    echo "Working on " . $package['name'] . "\n";
    chdir($config['install_path']);
    $package['slug_dir'] = str_replace("/", "_", $package['slug']);
    ensureDir($package['slug_dir']);
    chdir($package['slug_dir']);
    $release = getRelease($package['slug']);
    ensureDir($release->tag_name);
    chdir($release->tag_name);
    foreach ($release->assets as $asset) {
        $matcher = matcherPreparer($package['asset_matcher']);
        if ($matcher($asset->name)) {
            echo "  Found release " . $release->tag_name . " name " . $asset->name . " for " . $package['slug'] . "\n";
            echo "  Downloading...\n";
            system("wget  -q --show-progress -c " . escapeshellarg($asset->browser_download_url) . " -O " . escapeshellarg($asset->name));
            echo "  Postprocessing:\n";
            foreach ($package['post_process'] as $pp) {
                if (is_scalar($pp)) {
                    $pp = ["name" => $pp];
                }
                echo "    " . $pp['name'];
                $func_name = "PP_" . $pp['name'];
                if (!function_exists($func_name)) {
                    echo "\n  Post_processor " . $pp['name'] . " not found\n";
                    die(1);
                }
                $infoText = trim($func_name($asset, $pp, $package, $config));
                if (strlen($infoText)) {
                    if (strpos($infoText, "\n")) {
                        $infoText = "\n    > " . str_replace("\n", "\n    > ", $infoText);
                    } else {
                        $infoText = "($infoText)";
                    }
                }
                echo " ✓  $infoText\n";

            }
            echo "\n";
            continue 2;
        }
    }
    echo "didn't found any sutable asset or release for " . $package['slug'] . "\n";
    die(1);
}