local M = {}
require('codeit.ui.notifications').install()
local session = require('codeit.chat.state').new(require('codeit.settings.defaults'))
-- Each component closes over this explicit session and helper interface. Components
-- never require the public facade, so registration cannot create dependency cycles.
local helpers = {}
for _, component in ipairs({
  'chat.session', 'chat.usage', 'context.messages',
  'context.turn_review', 'context.editing', 'context.compactor', 'chat.requests',
  'chat.input', 'settings.actions', 'chat.history', 'settings.setup',
}) do
  require('codeit.' .. component).attach(M, session, helpers)
end
return M
