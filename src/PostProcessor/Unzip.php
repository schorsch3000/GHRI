<?php

namespace GHRI\PostProcessor;

use GHRI\DataStructure\GithubAsset;

class Unzip extends UnpackArchive
{
    public function process(GithubAsset &$asset)
    {
        return $this->processArchive(
            $asset,
            'unzip -qq -u ' . escapeshellarg($asset->getName())
        );
    }
}
