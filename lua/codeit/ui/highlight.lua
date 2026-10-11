local M = {}
local states = {}
local aliases = {
  bash = 'sh', shell = 'sh', zsh = 'sh', console = 'sh',
  py = 'python', python3 = 'python', js = 'javascript', ts = 'typescript',
  yml = 'yaml', csharp = 'cs', ['c++'] = 'cpp', ['c#'] = 'cs',
}
local links = {
  CodeitHeading = 'Title', CodeitBold = 'Bold', CodeitItalic = 'Italic',
  CodeitInlineCode = 'String', CodeitLink = 'Underlined', CodeitList = 'Special',
  CodeitQuote = 'Comment', CodeitRule = 'Delimiter', CodeitFence = 'Delimiter',
  CodeitCodeBlock = 'Normal', CodeitTool = 'Comment',
}

function M.setup_roles()
  local light = vim.o.background == 'light'
  vim.api.nvim_set_hl(0, 'CodeitUser', {
    default = true, fg = light and '#005faf' or '#61afef', ctermfg = light and 25 or 75, bold = true,
  })
  vim.api.nvim_set_hl(0, 'CodeitAssistant', {
    default = true, fg = light and '#875f00' or '#e5c07b', ctermfg = light and 94 or 180, bold = true,
  })
  vim.api.nvim_set_hl(0, 'CodeitMessageDisabled', {
    default = true, fg = light and '#767676' or '#808080', ctermfg = light and 243 or 244, bold = true,
  })
  vim.api.nvim_set_hl(0, 'CodeitTool', { default = true, link = 'Comment' })
  vim.api.nvim_set_hl(0, 'CodeitApprovalWarning', {
    default = true, fg = light and '#875f00' or '#ffaf00', ctermfg = light and 94 or 214, bold = true,
  })
  vim.api.nvim_set_hl(0, 'CodeitApprovalRisk', {
    default = true, fg = light and '#af0000' or '#ff5f5f', ctermfg = light and 124 or 203, bold = true,
  })
end

vim.api.nvim_create_autocmd('ColorScheme', {
  group = vim.api.nvim_create_augroup('codeit_role_highlights', { clear = true }),
  callback = M.setup_roles,
})

local function region(group, fence, language, cluster)
  local char = fence == '`' and '`' or '\\~'
  local suffix = language and ('\\s*\\c' .. vim.fn.escape(language, [[\.^$~[]*]]) .. '\\s*$') or '[^' .. fence .. ']*$'
  vim.cmd(('syntax region %s matchgroup=CodeitFence start=/^\\s*\\z(%s\\{3,}\\)%s/ end=/^\\s*\\z1%s*\\s*$/ keepend%s')
    :format(group, char, suffix, char, cluster and (' contains=@' .. cluster) or ''))
end

local function languages(buf, state)
  local found = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local fence, language = line:match('^%s*([`~]+)%s*([%w_+.#-]+)%s*$')
    if fence and #fence >= 3 and (fence:match('^`+$') or fence:match('^~+$')) then
      found[language:lower()] = true
    end
  end
  vim.api.nvim_buf_call(buf, function()
    for language in pairs(found) do
      if not state.languages[language] then
        state.languages[language] = true
        local syntax = aliases[language] or language
        -- Only runtime syntax files are sourced; fence labels never become Ex commands or paths.
        if syntax:match('^[%w_+-]+$') and syntax ~= 'codeit' and syntax ~= 'markdown'
          and #vim.api.nvim_get_runtime_file('syntax/' .. syntax .. '.vim', false) > 0 then
          local cluster = state.clusters[syntax]
          if not cluster then
            cluster = 'CodeitLanguage' .. tostring(state.next_cluster)
            state.next_cluster = state.next_cluster + 1
            local bash = vim.b[buf].is_bash
            if syntax == 'sh' then vim.b[buf].is_bash = 1 end
            vim.b[buf].current_syntax = nil
            vim.cmd('syntax include @' .. cluster .. ' syntax/' .. syntax .. '.vim')
            vim.b[buf].is_bash = bash
            vim.b[buf].current_syntax = 'codeit'
            state.clusters[syntax] = cluster
          end
          region('CodeitCodeBlock', '`', language, cluster)
          region('CodeitCodeBlock', '~', language, cluster)
        end
      end
    end
  end)
end

function M.load(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  M.setup_roles()
  for group, link in pairs(links) do vim.api.nvim_set_hl(0, group, { default = true, link = link }) end
  local state = { languages = {}, clusters = {}, next_cluster = 1 }
  states[buf] = state
  vim.api.nvim_buf_call(buf, function()
    vim.cmd([[
      syntax match CodeitHeading /^\s*#\{1,6}\s.*/
      syntax match CodeitRule /^\s*\([-*_]\)\(\s*\1\)\{2,}\s*$/
      syntax match CodeitList /^\s*\([-+*]\|\d\+[.)]\)\ze\s/
      syntax match CodeitQuote /^\s*>.*/
      syntax match CodeitLink /\[[^]\n]*\]([^ )]*\%([ ][^)]*\)\?)/
      syntax region CodeitItalic start=/\(^\|\s\)\zs\*\ze[^* ]/ end=/\*/ oneline
      syntax region CodeitBold start=/\*\*\ze\S/ end=/\*\*/ oneline
      syntax region CodeitInlineCode start=/\z(`\+\)/ end=/\z1/ oneline
      syntax match CodeitUser /^\*\*You\*\*$/
      syntax match CodeitAssistant /^\*\*Assistant\*\*$/
      syntax match CodeitTool /^\*\*Tool\%(: .*\)\?\*\*$/
      syntax sync fromstart
    ]])
    region('CodeitCodeBlock', '`')
    region('CodeitCodeBlock', '~')
    vim.b[buf].current_syntax = 'codeit'
  end)
  languages(buf, state)
  -- Rendering and streamed tokens change hidden buffers too, without TextChanged events.
  if not vim.b[buf].codeit_highlight_attached then
    vim.b[buf].codeit_highlight_attached = true
    vim.api.nvim_buf_attach(buf, false, {
      on_lines = function()
        local current = states[buf]
        if not current or current.pending then return end
        current.pending = true
        vim.schedule(function()
          current.pending = false
          if states[buf] == current and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].syntax == 'codeit' then
            languages(buf, current)
          end
        end)
      end,
      on_detach = function() states[buf] = nil end,
    })
  end
end

function M.enable(buf)
  vim.bo[buf].filetype = 'codeit'
  vim.bo[buf].syntax = 'codeit'
  if vim.b[buf].current_syntax ~= 'codeit' then M.load(buf) end
end

return M
