return vim.tbl_extend('force', {},
  require('codeit.settings.definitions'),
  require('codeit.settings.validation'),
  require('codeit.settings.resolution'),
  require('codeit.settings.persistence'))
