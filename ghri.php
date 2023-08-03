#!/usr/bin/env php
<?php
use GHRI\DataStructure\GithubAsset;
use GHRI\Matcher;
use GHRI\PostProcessor\APostProcessor;
use Colors\Color;
use GHRI\Worker\Config;
use GHRI\Worker\InstallPackage;
use GHRI\Worker\Wizzard;

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

$config = Config::get();

if ($_SERVER['argc'] === 1) {
    $installer = new InstallPackage($config, [], $color);

    $installer->installPackages();
} else {
    $params = $_SERVER['argv'];
    array_shift($params);
    $command = array_shift($params);
    switch ($command) {
        case 'i':
        case 'install':
            $installer = new InstallPackage($config, $params, $color);
            $installer->installPackages();
            break;
        default:
            help();
            break;
    }
}

