<?php

namespace GHRI\PostProcessor;

use GHRI\DataStructure\GithubAsset;
use function array_unshift;
use function ob_clean;
use function ob_get_clean;

class Testrun extends APostProcessor
{
    public function process(GithubAsset &$asset)
    {
        arrayDefault($this->postProcessor, 'quiet', false);
        arrayDefault($this->postProcessor, 'args', []);
        $command = (array) $this->postProcessor['args'];

        array_unshift(
            $command,
            isset($this->package['link'])
                ? $this->config['symlink_path'] . '/' . $this->package['name']
                : $this->package['name']
        );

        array_walk($command, function (&$value) {
            $value = escapeshellarg($value);
        });
        $command = '2>&1 ' . implode(' ', $command);
        ob_start();
        system($command, $retval);
        if (0 !== $retval) {
            fatal("Error running $command, exit code was $retval");
        }
        if ($this->postProcessor['quiet']) {
            ob_clean();
        }
        $this->infotext = trim(ob_get_clean());
        return $retval === 0;
    }
}
