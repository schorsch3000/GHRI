<?php
function PPName2PPClassName($name)
{
    $className = 'GHRI\\PostProcessor\\';
    $name = explode('_', strtolower($name));
    array_walk($name, function (&$value) {
        $value = ucfirst($value);
    });
    return $className . implode($name);
}
