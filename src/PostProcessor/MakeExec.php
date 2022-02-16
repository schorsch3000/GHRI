<?php

namespace GHRI\PostProcessor;

use GHRI\DataStructure\GithubAsset;

class MakeExec extends APostProcessor
{
    public function process(GithubAsset &$asset)
    {
        return chmod($asset->getName(), 0755);
    }
}
