'use strict'

// Filter cluster list to interactive-only
function filter_interactive_clusters() {
  let initial = true;
  $('#batch_connect_session_context_cluster option').each(function () {
    if (this.text.includes('interactive')) {
      $(this).show();
      if (initial) { $(this).prop('selected', true); initial = false; }
    } else {
      $(this).hide();
    }
    // Clean up label: remove '_interactive' suffix
    $(this).attr('label', this.text.replace('_interactive', ''));
  });
  // Hide the cluster label header (matches slac-ood-jupyter pattern)
  $('#batch_connect_session_context_cluster').siblings().hide();
}

// Mask the API key field as password-type
function mask_api_key() {
  let input = $('#batch_connect_session_context_api_key');
  input.attr('type', 'password');
  input.attr('autocomplete', 'off');
  input.attr('data-lpignore', 'true');
  input.attr('data-1p-ignore', 'true');
}

// Main
filter_interactive_clusters();
mask_api_key();
