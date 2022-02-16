<?php

namespace GHRI\PostProcessor;

use GHRI\DataStructure\GithubAsset;
use function ob_start;

class Bz2 extends UnpackArchive
{
    public function process(GithubAsset &$asset)
    {
        return $this->processArchive(
            $asset,
            'bunzip2 -k -f ' . escapeshellarg($asset->getName())
        );
    }
}
