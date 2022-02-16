<?php

namespace GHRI\DataStructure;

use function property_exists;

class SimpleDataStructure
{
    public function __construct($data)
    {
        foreach ($data as $k => $v) {
            if (!property_exists($this, $k)) {
                continue;
            }
            switch ($k) {
                case 'uploader':
                    $this->$k = new GithubUploader($v);
                    break;
                default:
                    $this->$k = $v;
            }
        }
    }
}
