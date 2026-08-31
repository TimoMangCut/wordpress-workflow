<?php
class DynHook {
    private $action = 'search';
    public function __construct() {
        add_action( 'wp_ajax_' . $this->action, [ $this, 'handle' ] );  // dynamic -> unresolved
    }
    public function handle() { echo 'x'; }
}
