<?php

namespace GHRI\PostProcessor;

use GHRI\DataStructure\GithubAsset;
use function assert;
use function escapeshellarg;
use function exec;
use function realpath;
use function var_dump;

class CheckInPath extends APostProcessor
{
    public function process(GithubAsset &$asset)
    {
        $cmd = 'command -v ' . escapeshellarg($this->package['link']);
        exec($cmd, $output, $exitcode);
        if ($exitcode !== 0) {
            $this->infotext = join("\n", $output);
            return false;
        }
        if (count($output) !== 1) {
            $this->infotext = join("\n", $output);
            return false;
        }
        if (realpath($output[0]) !== realpath($asset->getName())) {
            $this->infotext =
                "$cmd gives us " .
                join("\n", $output) .
                "\n but we expected " .
                $this->package['link'];
            return false;
        }
        return true;
    }
}
