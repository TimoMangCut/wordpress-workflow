<?php
class NoPrivAjax {
    public function __construct() {
        add_action( 'wp_ajax_nopriv_do_thing', [ $this, 'do_thing' ] );  // unauth
    }
    public function do_thing() {
        $q = $_POST['q'];
        global $wpdb;
        $wpdb->query( "SELECT * FROM t WHERE n = '$q'" );  // unsanitized sql sink
    }
}
