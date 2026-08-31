<?php
class Guards {
    public function __construct() {
        add_action( 'wp_ajax_effective', [ $this, 'effective' ] );
        add_action( 'wp_ajax_ineffective', [ $this, 'ineffective' ] );
    }
    public function effective() {
        if ( ! current_user_can( 'manage_options' ) ) { wp_die(); }   // effective: gates
        update_option( 'x', 1 );
    }
    public function ineffective() {
        $ok = current_user_can( 'manage_options' );                   // ineffective: result unused
        update_option( 'x', 1 );
    }
}
