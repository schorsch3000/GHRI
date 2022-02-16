<?php

namespace GHRI\PostProcessor;

use GHRI\DataStructure\GithubAsset;

class Tar extends UnpackArchive
{
    public function process(GithubAsset &$asset)
    {
        return $this->processArchive(
            $asset,
            'tar -xf ' . escapeshellarg($asset->getName())
        );
    }
}
