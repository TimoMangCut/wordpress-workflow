<?php
class Storage {
    public function __construct() {
        add_action( 'wp_ajax_nopriv_save', [ $this, 'save' ] );
        add_action( 'wp_ajax_nopriv_load', [ $this, 'load' ] );
    }
    public function save() { update_option( 'my_key', $_POST['v'] ); }        // write key my_key
    public function load() { echo get_option( 'my_key' ); }                    // read key my_key
}
