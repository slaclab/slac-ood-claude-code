'use strict'

function toggle_visibility_of_form_group(form_id, show) {
  let form_element = $(form_id);
  let parent = form_element.parent();
  if (show) {
    parent.show();
  } else {
    form_element.val('');
    parent.hide();
  }
}

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

// Populate SIF version dropdown from available SIF files.
// SIF files are named claude-code_<version>.sif under /sdf/sw/ai/claude-code/.
// The list is embedded at render time via ERB so no client-side filesystem access needed.
function populate_sif_versions() {
  let select = $('#batch_connect_session_context_sif_version');
  select.empty();
  let sifs = <%= Dir.glob("/sdf/sw/ai/claude-code/claude-code_*.sif")
                   .map { |f| File.basename(f, '.sif') }
                   .sort
                   .reverse
                   .to_json %>;
  if (sifs.length === 0) {
    // Fallback: no SIFs found at the standard path
    select.append($('<option>', { value: 'latest', text: 'latest (default)' }));
    return;
  }
  sifs.forEach(function(name, i) {
    let version = name.replace('claude-code_', '');
    let label = (i === 0) ? version + ' (latest)' : version;
    select.append($('<option>', {
      value: '/sdf/sw/ai/claude-code/' + name + '.sif',
      text: label,
      selected: i === 0
    }));
  });
}

// Main
filter_interactive_clusters();
mask_api_key();
populate_sif_versions();
