vim.opt.runtimepath:prepend(vim.fn.getcwd())
local description = require('codeit.skill_frontmatter').description
local function check(frontmatter, expected)
  local actual = description('---\n' .. frontmatter .. '\n---\nSkill body')
  assert(actual == expected, vim.inspect({ frontmatter = frontmatter, expected = expected, actual = actual }))
end

check('description: Check changes carefully', 'Check changes carefully')
check('name: review\ndescription:  Check changes carefully  # comment', 'Check changes carefully')
check('description: Read #comment', 'Read')
check('description: Read#fragment', 'Read#fragment')
check([[description: 'Review: it''s # important' # comment]], "Review: it's # important")
check([[description: "Review \"quotes\" and \\ paths" # comment]], 'Review "quotes" and \\ paths')
check([[description: "line\nnext\tcolumn\u263A\x21\U0001F600"]], 'line\nnext\tcolumn☺!😀')
check([[description: '\n stays literal']], '\\n stays literal')
check('description: |\n  First line\n  Second line', 'First line\nSecond line\n')
check('description: |- # comment\n  First line\n  Second line\n\n', 'First line\nSecond line')
check('description: |+\n  First line\n\n', 'First line\n\n\n')
check('description: >\n  First line\n  Second line', 'First line Second line\n')
check('description: >-\n  First paragraph\n\n  Second paragraph', 'First paragraph\nSecond paragraph')
check('description: >-\n  First paragraph\n\n\n  Second paragraph', 'First paragraph\n\nSecond paragraph')
check('description: >-\n\n  First paragraph', '\nFirst paragraph')
check('description: >-\n  First line\n    Indented\n    Code\n  Last line', 'First line\n  Indented\n  Code\nLast line')
check('description: |2-\n  First line\n    Indented\nname: ignored', 'First line\n  Indented')
check('description: >-2\n  First line\n  Second line\nother: value', 'First line Second line')
assert(description('---\r\nname: review\r\ndescription: >-\r\n  First\r\n  second\r\n---\r\nbody') == 'First second')
assert(description('---\ndescription: "CRLF"\n---') == 'CRLF')
assert(description('---\ndescription: ignored\n---not-a-delimiter\nbody') == nil)
assert(description('---\ndescription: ignored\nbody') == nil)
assert(description('body\n---\ndescription: ignored\n---') == nil)
assert(description('---\nname: review\n---\ndescription: body') == nil)
for _, value in ipairs({
  '', '# comment', "''", '""', 'true', 'false', 'null', '~', '123', '[one, two]', '{key: value}',
  '*alias', '&anchor text', '!tag text', 'bad: mapping', '"unterminated', "'unterminated",
  '"value"garbage', "'value'#comment", '"bad\\q"', '"bad\\u123"', '"bad\\uD800"',
  '"bad\\U00110000"', '|0', '>--', '|22', '|garbage',
}) do
  check('description: ' .. value, nil)
end
check('description: |\n  \n', nil)
check('description: |2\n one space', nil)
check('description: |\n  good\n bad', nil)
check('description: first\n  second', nil)
check('description: "first"\n  second', nil)
check('description: first\ndescription: second', nil)
check('name: review', nil)
local manual_only = require('codeit.skill_frontmatter').disable_model_invocation
local function check_manual(frontmatter, expected)
  assert(manual_only('---\n' .. frontmatter .. '\n---\nBody') == expected, frontmatter)
end
check_manual('description: normal', false)
check_manual('disable-model-invocation: false', false)
check_manual('disable-model-invocation: FALSE # comment', false)
check_manual('disable-model-invocation: true', true)
check_manual('description: normal\ndisable-model-invocation: True # comment', true)
check_manual('description: |-\n  disable-model-invocation: true', false)
for _, value in ipairs({ '', '# empty', '"false"', 'no', '0', '[]', 'false#comment', '|', 'false\n  extra' }) do
  check_manual('disable-model-invocation: ' .. value, true)
end
check_manual('disable-model-invocation: false\ndisable-model-invocation: false', true)
assert(not manual_only('No frontmatter'))
assert(manual_only('---\r\ndisable-model-invocation: true\r\n---\r\nBody'))
print('codeit skill frontmatter tests passed')
