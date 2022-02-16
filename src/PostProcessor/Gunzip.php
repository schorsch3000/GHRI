<?php

namespace GHRI\PostProcessor;

use GHRI\DataStructure\GithubAsset;
use function ob_start;

class Gunzip extends APostProcessor
{
    public function process(GithubAsset &$asset)
    {
        ob_start();
        system(
            '2>&1 gunzip -f -k ' . escapeshellarg($asset->getName()),
            $retval
        );
        $asset->setName(basename($asset->getName(), '.gz'));
        if (0 !== $retval) {
            fatal("error running gunzip, exit code was $retval");
        }
        $this->infotext = ob_get_clean();
        return $retval === 0;
    }
}
