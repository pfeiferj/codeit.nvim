if exists('b:current_syntax')
  finish
endif
lua require('codeit.ui.highlight').load(vim.api.nvim_get_current_buf())
