<?php
header("Cache-Control: no-store, no-cache, must-revalidate");
header("Pragma: no-cache");
readfile(__DIR__ . "/index.htm");
