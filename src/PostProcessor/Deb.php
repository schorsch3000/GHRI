<?php

namespace GHRI\PostProcessor;

use GHRI\DataStructure\GithubAsset;
use function escapeshellarg;
use function var_dump;

class Deb extends APostProcessor
{
    public function process(GithubAsset &$asset)
    {
        if (!isset($this->package['deb_name'])) {
            $this->package['deb_name'] = $this->package['name'];
        }

        if (
            !$this->isInstalled($this->package['deb_name']) ||
            $this->getInstalledVersion($this->package['deb_name']) !==
                $this->getDebVersion($asset->getName())
        ) {
            system('tput smcup');
            echo 'We need to install this ' .
                $asset->getName() .
                " so we ask your for your sudeo password...\n";
            system(
                'sudo dpkg -i ' . escapeshellarg($asset->getName()),
                $rescode
            );
            system('tput rmcup');
            return $rescode === 0;
        }
        return true;
    }
    public function isInstalled($package)
    {
        exec(
            "dpkg -l  | grep '^ii' | sed  's/\s\s*/ /g' | cut -d' ' -f2",
            $output
        );
        foreach ($output as $line) {
            if (trim($line) === $package) {
                return true;
            }
        }
        return false;
    }
    public function getInstalledVersion($package)
    {
        exec(
            "dpkg -l  | grep '^ii' | sed  's/\s\s*/ /g' | cut -d' ' -f2-3",
            $packages
        );
        foreach ($packages as $line) {
            $data = explode(' ', trim($line));
            if ($data[0] !== $package) {
                continue;
            }
            return $data[1];
        }
    }
    public function getDebVersion($file)
    {
        exec('dpkg-deb -f ' . escapeshellarg($file) . ' Version', $out);
        return $out[0];
    }
}
