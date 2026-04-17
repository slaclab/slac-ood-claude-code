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

  // Inject help text (OOD ignores help: for the cluster widget)
  const $cluster = $('#batch_connect_session_context_cluster');
  if ($cluster.closest('.form-group').find('.form-text').length === 0) {
    $('<small class="form-text text-muted">Choose the interactive cluster associated with your experiment or data.</small>')
      .insertAfter($cluster);
  }

  // Override the cluster label (OOD ignores label: for the cluster widget)
  $cluster.closest('.form-group').find('label').first().text('Run on Cluster');
}

// Mask the API key field as password-type
function mask_api_key() {
  let input = $('#batch_connect_session_context_slac_bedrock_key');
  input.attr('type', 'password');
  input.attr('autocomplete', 'off');
  input.attr('data-lpignore', 'true');
  input.attr('data-1p-ignore', 'true');
}

// Show/hide fields based on provider selection.
// Disabled hidden fields are not submitted and not validated as required.
function toggle_field(id, visible) {
  const el = $('#batch_connect_session_context_' + id);
  el.closest('.form-group').toggle(visible);
  el.prop('disabled', !visible);
}

const PROVIDER_HELP = {
  bedrock:  'Use a personal SLAC AI API key. ' +
            '<a href="https://slacprod.servicenowservices.com/it_services?id=sc_cat_item&sys_id=515f28711b607110c5d320eae54bcb64&sysparm_category=d65827c46fd921009c4235af1e3ee434" target="_blank">Request one via ServiceNow</a>.',
  sdf_sage: 'Use your facility allocation quota — no personal key needed. ' +
            'Choose this if your experiment has a repo allocation on <code>llm.sdf.slac.stanford.edu</code>.',
};

function update_provider_fields() {
  const provider = $('#batch_connect_session_context_llm_provider').val();
  const is_bedrock  = provider === 'bedrock';
  const is_sdf_sage = provider === 'sdf_sage';

  toggle_field('slac_bedrock_key',   is_bedrock);
  toggle_field('sdf_sage_provider', is_sdf_sage);
  toggle_field('sdf_sage_repo',     is_sdf_sage);

  const help_text = PROVIDER_HELP[provider] || '';
  const $group = $('#batch_connect_session_context_llm_provider').closest('.form-group');
  let $help = $group.find('.form-text');
  if ($help.length === 0) {
    $help = $('<small class="form-text text-muted"></small>');
    $group.append($help);
  }
  $help.html(help_text);
}

// Main
filter_interactive_clusters();
mask_api_key();
$('#batch_connect_session_context_llm_provider').on('change', update_provider_fields);
update_provider_fields();
