<?php

function arrayDefault(array &$array, $field, $value)
{
    $array[$field] = isset($array[$field]) ? $array[$field] : $value;
}
