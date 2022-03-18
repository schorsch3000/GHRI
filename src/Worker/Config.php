<?php

namespace GHRI\Worker;

use function array_filter;
use function count;
use function ensureDir;
use function explode;
use function fatal;
use function implode;
use function preg_match;
use function realpath;
use function yaml_parse_file;

class Config
{
    public static function normalize($config)
    {
        foreach ($config as $k => $v) {
            if (!preg_match("/_path$/", $k)) {
                continue;
            }
            ensureDir($v);
            $config[$k] = realpath($v);
        }

        $names = [];
        foreach ($config['packages'] as &$package) {
            $package['name'] =
                $package['name'] ?? explode('/', $package['slug'])[1];
            $names[$package['name']][] = $package['slug'];
            $package['post_process'] = $package['post_process'] ?? [];
        }

        $dblnames = array_filter($names, function ($name) {
            return count($name) > 1;
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
        return $config;
    }
    public static function get()
    {
        $config = yaml_parse_file('ghri.yaml');
        if (!$config) {
            fatal('Cant parse config file');
        }
        return self::normalize($config);
    }
}
