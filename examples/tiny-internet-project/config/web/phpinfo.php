<?php
// phpinfo.php — the classic "is PHP alive?" probe. Tonello's tutorial drops this
// into the web root to confirm Apache is handing .php files to the PHP module
// (not serving them as text). `curl http://web01.tiny.lab/phpinfo.php` should
// return an HTML dump of the PHP configuration; if you see this source instead,
// libapache2-mod-php isn't enabled.
phpinfo();
