#!/usr/bin/env php
<?php
use GHRI\DataStructure\GithubAsset;
use GHRI\Matcher;
use GHRI\PostProcessor\APostProcessor;
use Colors\Color;

define('IS_PHAR', substr(__DIR__, 0, 7) === 'phar://');

require_once __DIR__ . '/src/func.php';
require_once __DIR__ . '/vendor/autoload.php';

$color = new Color();
$color->setUserStyles([
    'error' => 'red',
    'header' => 'yellow',
    'okay' => 'green',
    'normal' => [],
    'highlight' => 'cyan',
]);

if (IS_PHAR) {
    chdir(dirname(substr(__DIR__, 7)));
} else {
    chdir(__DIR__);
}
$config = yaml_parse_file('config.yaml');
if (!$config) {
    fatal('Cant parse config file');
}

foreach ($config as $k => $v) {
    if (!preg_match("/_path$/", $k)) {
        continue;
    }
    ensureDir($v);
    $config[$k] = realpath($v);
}

$names = [];
foreach ($config['packages'] as &$package) {
    $package['name'] = isset($package['name'])
        ? $package['name']
        : explode('/', $package['slug'])[1];
    $names[$package['name']][] = $package['slug'];
    $package['post_process'] = isset($package['post_process'])
        ? $package['post_process']
        : [];
}

$dblnames = array_filter($names, function ($a) {
    return count($a) > 1;
});

if (count($dblnames)) {
    $msg =
        "There are duplicate names in the config, therefore we can't go in:\n";

    foreach ($dblnames as $dblname => $slugs) {
        $msg .=
            "Duplicate for name $dblname in slugs: " .
            implode(', ', $slugs) .
            "\n";
    }

    fatal($msg);
}

$installations = [];

foreach ($config['packages'] as &$package) {
    if ($_SERVER['argc'] === 2 && $package['name'] !== $_SERVER['argv'][1]) {
        continue;
    }
    echo $color('Working on ' . $package['name'] )->header;
    if(isset($package['desc'])){
        echo $color(":  ".trim($package['desc']))->header->bold;
    }
    echo "\n";
    chdir($config['install_path']);
    $package['slug_dir'] = str_replace('/', '_', $package['slug']);
    ensureDir($package['slug_dir']);
    chdir($package['slug_dir']);
    $release = getRelease($package['slug']);
    ensureDir($release->tag_name);
    chdir($release->tag_name);
    foreach ($release->assets as $asset) {
        $asset = new GithubAsset($asset);

        $matcher = Matcher::createFromString($package['asset_matcher']);
        if ($matcher($asset->getName())) {
            echo $color('  Found release ')->normal;
            echo $color($release->tag_name)->highlight;
            echo $color(' name ')->normal;
            echo $color($asset->getName())->highlight;
            echo $color(' for ')->normal;
            echo $color($package['slug'])->highlight;
            echo $color("\n")->normal;
            echo $color("  Downloading...\n")->normal;
            system(
                'wget  -q --show-progress -c ' .
                    escapeshellarg($asset->getBrowserDownloadUrl()) .
                    ' -O ' .
                    escapeshellarg($asset->getName())
            );
            echo $color("  Postprocessing:\n")->header;
            foreach (
                array_merge(
                    (array) $config['global_post_process']['prepend'],
                    (array) $package['post_process'],
                    (array) $config['global_post_process']['append']
                )
                as $pp
            ) {
                if (is_scalar($pp)) {
                    $pp = ['name' => $pp];
                }
                echo $color('    ' . $pp['name'])->normal;
                $class_name = PPName2PPClassName($pp['name']);

                if (!class_exists($class_name)) {
                    fatal(
                        "\n  Post_processor " .
                            $pp['name'] .
                            "($class_name) not found"
                    );
                }
                $ppo = new $class_name($pp, $package, $config);
                /** @var APostProcessor $ppo */
                $success = $ppo->process($asset); //TODO, auswerten!
                $infoText = $ppo->getInfotext();
                if (strlen($infoText)) {
                    if (false !== strpos($infoText, "\n")) {
                        $prefix = (string) $color("\n      > ")->normal;
                        $infoText = explode("\n", $infoText);
                        foreach ($infoText as $k => $v) {
                            $infoText[$k] = (string) $color($v)->highlight;
                        }
                        array_unshift($infoText, null);
                        $infoText = implode($prefix, $infoText);
                    } else {
                        $infoText = '(' . $color($infoText)->highlight . ')';
                    }
                }
                if ($success) {
                    echo $color(' ✓ ')->okay->bold;
                    echo "$infoText\n";
                } else {
                    echo $color(' ❌ ')->error->bold;
                    echo "$infoText\n";
                    die(1);
                }
            }
            echo "\n";
            continue 2;
        }
    }
    fatal(
        "didn't found any suitable asset or release for " .
            $package['slug'] .
            "\n"
    );
}

