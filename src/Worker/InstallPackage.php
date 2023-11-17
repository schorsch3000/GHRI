<?php

namespace GHRI\Worker;

use Colors\Color;
use GHRI\DataStructure\GithubAsset;
use GHRI\Matcher;
use GHRI\PostProcessor\APostProcessor;
use function array_merge;
use function array_unshift;
use function chdir;
use function class_exists;
use function ensureDir;
use function escapeshellarg;
use function explode;
use function fatal;
use function getRelease;
use function implode;
use function in_array;
use function is_scalar;
use function PPName2PPClassName;
use function str_replace;
use function strlen;
use function strpos;
use function system;
use function trim;

class InstallPackage
{
    /**
     * @var array
     */
    private $config;
    /**
     * @var string[]
     */
    private $packages;

    /**
     * @var Color
     */
    private $color;

    /**
     * @param array $config
     * @param array|string|null $packages
     * @param Color $color
     */
    public function __construct(array $config, $packages, Color $color)
    {
        $this->config = $config;
        $this->packages = (array) $packages;
        $this->color = $color;
    }
    public function installPackages()
    {
        $color = $this->color;
        foreach ($this->config['packages'] as &$package) {
            if (
                count($this->packages) &&
                !in_array($package['name'], $this->packages)
            ) {
                continue;
            }
            if(!count($this->packages) && !$package['auto_install']){
                echo $color('Skipping ' . $package['name'].' since tis set to not autoinstall')->highlight->bold,"\n";
                continue;
            }

            echo $color('Working on ' . $package['name'])->header;
            if (isset($package['desc'])) {
                echo $color(':  ' . trim($package['desc']))->header->bold;
            }
            echo "\n";
            chdir($this->config['install_path']);
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
                            (array) $this->config['global_post_process'][
                                'prepend'
                            ],
                            (array) $package['post_process'],
                            (array) $this->config['global_post_process'][
                                'append'
                            ]
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
                        $ppo = new $class_name($pp, $package, $this->config);
                        /** @var APostProcessor $ppo */
                        $success = $ppo->process($asset); //TODO, auswerten!
                        $infoText = $ppo->getInfotext();
                        if (strlen($infoText)) {
                            if (false !== strpos($infoText, "\n")) {
                                $prefix = (string) $color("\n      > ")->normal;
                                $infoText = explode("\n", $infoText);
                                foreach ($infoText as $k => $v) {
                                    $infoText[$k] = (string) $color($v)
                                        ->highlight;
                                }
                                array_unshift($infoText, null);
                                $infoText = implode($prefix, $infoText);
                            } else {
                                $infoText =
                                    '(' . $color($infoText)->highlight . ')';
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
    }
}
