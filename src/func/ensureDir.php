<?php
function ensureDir($dir)
{
    if (is_dir($dir)) {
        return true;
    }
    mkdir($dir, 0777, true);
    if (is_dir($dir)) {
        return true;
    }
    fatal("can't create dir $dir");
}
