<?php
class DynHook {
    const ENDPOINT = 'create-order';
    private $action = 'search';
    private $hook_name = 'x';
    public function __construct() {
        // Known action prefix + dynamic suffix -> resolvable to an entry point (low confidence),
        // NOT dropped. This is the wc_ajax / wp_ajax blind-spot fix.
        add_action( 'wp_ajax_' . $this->action, [ $this, 'handle' ] );        // -> ajax_priv, dynamic
        add_action( 'wc_ajax_' . self::ENDPOINT, [ $this, 'handle' ] );       // -> wc_ajax (auth none), dynamic
        add_action( 'wc_ajax_literal_thing', [ $this, 'handle' ] );          // -> wc_ajax (auth none), literal
        // No recognizable literal prefix -> genuinely unresolved, still captured (no silent drop).
        add_action( 'custom_prefix_' . $this->action, [ $this, 'handle' ] );  // -> unresolved_hooks (concatenation)
    }
    public function handle() { echo 'x'; }
}
