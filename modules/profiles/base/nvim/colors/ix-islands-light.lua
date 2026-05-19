-- ix-islands-light
--
-- Faithful port of JetBrains' Islands Light theme to Neovim. Colors
-- mirror the IntelliJ source (ManyIslandsLight.theme.json, Light.xml).
-- See ix-islands-dark.lua for the dark variant; group layout is
-- identical so the two files diff cleanly as a palette swap.

vim.cmd("highlight clear")
if vim.fn.exists("syntax_on") == 1 then
  vim.cmd("syntax reset")
end
vim.o.background = "light"
vim.g.colors_name = "ix-islands-light"

local c = {
  bg                  = "#FFFFFF",
  fg                  = "#080808",
  cursor              = "#000000",
  line_hl             = "#F7F8FF",
  selection           = "#D0DFFE",
  inactive_selection  = "#E9EAEE",
  word_hl             = "#D6E4F2",
  word_hl_strong      = "#F0D5D5",
  find_match          = "#D6F3E2",
  find_match_hl       = "#D6F3E280",

  line_nr             = "#9FA2A8",
  line_nr_active      = "#5F6269",
  bracket_match       = "#93D9D9",
  indent_guide        = "#E9EAEE",
  indent_guide_active = "#D1D3D9",
  whitespace          = "#D1D3D9",

  ui_panel            = "#F7F8FF",
  ui_input_bg         = "#FFFFFF",
  ui_input_border     = "#D1D3D9",
  ui_border           = "#3871E1",
  ui_dim              = "#5F6269",
  ui_subtle_bg        = "#F7F8FF",
  ui_hover_bg         = "#00000008",

  error               = "#C54E58",
  warning             = "#A56906",
  info                = "#2F5EB9",
  hint                = "#2F5EB9",
  diag_unnecessary    = "#9FA2A8",

  git_add             = "#4E9D6C",
  git_change          = "#538AF9",
  git_delete          = "#E4656E",

  -- Syntax
  comment             = "#8C8C8C",
  doc_comment         = "#8C8C8C",
  doc_comment_tag     = "#999999",
  doc_tag_value       = "#3D3D3D",
  string              = "#067D17",
  string_escape       = "#0037A6",
  number              = "#1750EB",
  keyword             = "#0033B3",
  storage             = "#0033B3",
  operator            = "#080808",
  func                = "#00627A",
  static              = "#00627A",
  type                = "#336ECC",
  type_param          = "#007E8A",
  variable            = "#080808",
  constant            = "#871094",
  property            = "#871094",
  parameter           = "#080808",
  this_self           = "#0033B3",
  punctuation         = "#080808",
  tag                 = "#000080",
  attribute           = "#174AD4",
  decorator           = "#9E880D",
  regexp              = "#264EFF",
  jsx_component       = "#AD6339",
  html_custom         = "#007EBD",
  shell_var           = "#871094",
  todo                = "#008DDE",
  invalid             = "#C54E58",
  link                = "#2F5EB9",
  heading             = "#0033B3",
}

local hi = function(group, opts) vim.api.nvim_set_hl(0, group, opts) end

-- Editor / UI --------------------------------------------------------
hi("Normal",        { fg = c.fg,  bg = c.bg })
hi("NormalFloat",   { fg = c.fg,  bg = c.ui_subtle_bg })
hi("FloatBorder",   { fg = c.ui_border, bg = c.ui_subtle_bg })
hi("FloatTitle",    { fg = c.fg,  bg = c.ui_subtle_bg, bold = true })
hi("Cursor",        { fg = c.bg,  bg = c.cursor })
hi("CursorLine",    { bg = c.line_hl })
hi("CursorColumn",  { bg = c.line_hl })
hi("ColorColumn",   { bg = c.line_hl })
hi("LineNr",        { fg = c.line_nr })
hi("CursorLineNr",  { fg = c.line_nr_active, bold = true })
hi("SignColumn",    { bg = c.bg })
hi("VertSplit",     { fg = c.ui_input_border, bg = c.bg })
hi("WinSeparator",  { fg = c.ui_input_border, bg = c.bg })
hi("Visual",        { bg = c.selection })
hi("VisualNOS",     { bg = c.inactive_selection })
hi("Search",        { bg = c.find_match })
hi("IncSearch",     { bg = c.find_match, fg = c.fg, bold = true })
hi("CurSearch",     { bg = c.find_match, fg = c.fg, bold = true })
hi("MatchParen",    { bg = c.bracket_match, bold = true })
hi("Folded",        { fg = c.ui_dim, bg = c.line_hl })
hi("FoldColumn",    { fg = c.line_nr, bg = c.bg })
hi("Whitespace",    { fg = c.whitespace })
hi("NonText",       { fg = c.whitespace })
hi("SpecialKey",    { fg = c.whitespace })
hi("Conceal",       { fg = c.comment })
hi("EndOfBuffer",   { fg = c.bg })
hi("Title",         { fg = c.heading, bold = true })
hi("Directory",     { fg = c.link })

-- Statusline / Tabline ----------------------------------------------
hi("StatusLine",       { fg = c.ui_dim, bg = c.ui_panel })
hi("StatusLineNC",     { fg = c.line_nr, bg = c.ui_panel })
hi("TabLine",          { fg = c.ui_dim, bg = c.ui_panel })
hi("TabLineFill",      { bg = c.ui_panel })
hi("TabLineSel",       { fg = c.fg, bg = c.bg, bold = true })
hi("WinBar",           { fg = c.ui_dim, bg = c.bg })
hi("WinBarNC",         { fg = c.line_nr, bg = c.bg })

-- Pmenu / completion -------------------------------------------------
hi("Pmenu",            { fg = c.fg, bg = c.ui_subtle_bg })
hi("PmenuSel",         { fg = c.fg, bg = c.selection, bold = true })
hi("PmenuSbar",        { bg = c.ui_subtle_bg })
hi("PmenuThumb",       { bg = c.line_nr })
hi("PmenuMatch",       { fg = c.func, bold = true })
hi("PmenuMatchSel",    { fg = c.func, bg = c.selection, bold = true })
hi("PmenuKind",        { fg = c.type, bg = c.ui_subtle_bg })
hi("PmenuExtra",       { fg = c.comment, bg = c.ui_subtle_bg })
hi("WildMenu",         { fg = c.fg, bg = c.selection })

-- Messages -----------------------------------------------------------
hi("ErrorMsg",         { fg = c.error, bold = true })
hi("WarningMsg",       { fg = c.warning })
hi("ModeMsg",          { fg = c.fg, bold = true })
hi("MoreMsg",          { fg = c.info })
hi("Question",         { fg = c.info })

-- Diagnostics --------------------------------------------------------
hi("DiagnosticError",            { fg = c.error })
hi("DiagnosticWarn",             { fg = c.warning })
hi("DiagnosticInfo",             { fg = c.info })
hi("DiagnosticHint",             { fg = c.hint })
hi("DiagnosticOk",               { fg = c.string })
hi("DiagnosticUnnecessary",      { fg = c.diag_unnecessary })
hi("DiagnosticUnderlineError",   { sp = c.error,   undercurl = true })
hi("DiagnosticUnderlineWarn",    { sp = c.warning, undercurl = true })
hi("DiagnosticUnderlineInfo",    { sp = c.info,    undercurl = true })
hi("DiagnosticUnderlineHint",    { sp = c.hint,    undercurl = true })
hi("DiagnosticVirtualTextError", { fg = c.error })
hi("DiagnosticVirtualTextWarn",  { fg = c.warning })
hi("DiagnosticVirtualTextInfo",  { fg = c.info })
hi("DiagnosticVirtualTextHint",  { fg = c.hint })

-- Spell --------------------------------------------------------------
hi("SpellBad",   { sp = c.error,   undercurl = true })
hi("SpellCap",   { sp = c.warning, undercurl = true })
hi("SpellLocal", { sp = c.info,    undercurl = true })
hi("SpellRare",  { sp = c.hint,    undercurl = true })

-- Classic syntax groups ----------------------------------------------
hi("Comment",       { fg = c.comment, italic = true })
hi("Constant",      { fg = c.constant })
hi("String",        { fg = c.string })
hi("Character",     { fg = c.string })
hi("Number",        { fg = c.number })
hi("Float",         { fg = c.number })
hi("Boolean",       { fg = c.keyword })
hi("Identifier",    { fg = c.variable })
hi("Function",      { fg = c.func })
hi("Statement",     { fg = c.keyword })
hi("Conditional",   { fg = c.keyword })
hi("Repeat",        { fg = c.keyword })
hi("Label",         { fg = c.keyword })
hi("Operator",      { fg = c.operator })
hi("Keyword",       { fg = c.keyword })
hi("Exception",     { fg = c.keyword })
hi("PreProc",       { fg = c.decorator })
hi("Include",       { fg = c.keyword })
hi("Define",        { fg = c.keyword })
hi("Macro",         { fg = c.keyword })
hi("PreCondit",     { fg = c.keyword })
hi("Type",          { fg = c.type })
hi("StorageClass",  { fg = c.storage })
hi("Structure",     { fg = c.type })
hi("Typedef",       { fg = c.type })
hi("Special",       { fg = c.string_escape })
hi("SpecialChar",   { fg = c.string_escape })
hi("Tag",           { fg = c.tag })
hi("Delimiter",     { fg = c.punctuation })
hi("SpecialComment",{ fg = c.doc_comment_tag })
hi("Debug",         { fg = c.warning })
hi("Underlined",    { fg = c.link, underline = true })
hi("Ignore",        { fg = c.line_nr })
hi("Error",         { fg = c.invalid })
hi("Todo",          { fg = c.todo, italic = true, bold = true })

-- Treesitter ---------------------------------------------------------
hi("@comment",                       { link = "Comment" })
hi("@comment.documentation",         { fg = c.doc_comment, italic = true })
hi("@comment.todo",                  { fg = c.todo, italic = true, bold = true })
hi("@comment.warning",               { fg = c.warning, bold = true })
hi("@comment.error",                 { fg = c.error, bold = true })
hi("@comment.note",                  { fg = c.info, italic = true })

hi("@string",                        { fg = c.string })
hi("@string.regexp",                 { fg = c.regexp })
hi("@string.escape",                 { fg = c.string_escape })
hi("@string.special",                { fg = c.string_escape })

hi("@character",                     { fg = c.string })
hi("@character.special",             { fg = c.string_escape })

hi("@number",                        { fg = c.number })
hi("@number.float",                  { fg = c.number })
hi("@boolean",                       { fg = c.keyword })

hi("@constant",                      { fg = c.constant, italic = true })
hi("@constant.builtin",              { fg = c.keyword })
hi("@constant.macro",                { fg = c.constant })

hi("@variable",                      { fg = c.variable })
hi("@variable.builtin",              { fg = c.this_self })
hi("@variable.parameter",            { fg = c.parameter })
hi("@variable.member",               { fg = c.property })

hi("@property",                      { fg = c.property })
hi("@field",                         { fg = c.property })

hi("@function",                      { fg = c.func })
hi("@function.builtin",              { fg = c.func })
hi("@function.call",                 { fg = c.func })
hi("@function.macro",                { fg = c.keyword })
hi("@function.method",               { fg = c.func })
hi("@function.method.call",          { fg = c.func })
hi("@method",                        { fg = c.func })

hi("@constructor",                   { fg = c.func })
hi("@parameter",                     { fg = c.parameter })

hi("@keyword",                       { fg = c.keyword })
hi("@keyword.function",              { fg = c.keyword })
hi("@keyword.operator",              { fg = c.keyword })
hi("@keyword.return",                { fg = c.keyword })
hi("@keyword.conditional",           { fg = c.keyword })
hi("@keyword.repeat",                { fg = c.keyword })
hi("@keyword.import",                { fg = c.keyword })
hi("@keyword.exception",             { fg = c.keyword })
hi("@keyword.modifier",              { fg = c.storage })
hi("@keyword.type",                  { fg = c.storage })
hi("@keyword.coroutine",             { fg = c.keyword })

hi("@operator",                      { fg = c.operator })

hi("@type",                          { fg = c.type })
hi("@type.builtin",                  { fg = c.keyword })
hi("@type.definition",               { fg = c.type })
hi("@type.qualifier",                { fg = c.storage })

hi("@attribute",                     { fg = c.decorator })
hi("@attribute.builtin",             { fg = c.decorator })

hi("@punctuation",                   { fg = c.punctuation })
hi("@punctuation.delimiter",         { fg = c.punctuation })
hi("@punctuation.bracket",           { fg = c.punctuation })
hi("@punctuation.special",           { fg = c.string_escape })

hi("@tag",                           { fg = c.tag })
hi("@tag.attribute",                 { fg = c.attribute })
hi("@tag.delimiter",                 { fg = c.tag })

hi("@markup.heading",                { fg = c.heading, bold = true })
hi("@markup.strong",                 { bold = true })
hi("@markup.italic",                 { italic = true })
hi("@markup.underline",              { underline = true })
hi("@markup.strikethrough",          { strikethrough = true })
hi("@markup.link",                   { fg = c.link, underline = true })
hi("@markup.link.label",             { fg = c.fg })
hi("@markup.link.url",               { fg = c.link, underline = true })
hi("@markup.raw",                    { fg = c.string })
hi("@markup.raw.block",              { fg = c.string })
hi("@markup.list",                   { fg = c.keyword })
hi("@markup.quote",                  { fg = c.comment, italic = true })

hi("@diff.plus",                     { fg = c.git_add })
hi("@diff.minus",                    { fg = c.git_delete })
hi("@diff.delta",                    { fg = c.git_change })

hi("@module",                        { fg = c.fg })
hi("@namespace",                     { fg = c.fg })
hi("@label",                         { fg = c.keyword })

-- LSP semantic -------------------------------------------------------
hi("@lsp.type.namespace",            { link = "@namespace" })
hi("@lsp.type.type",                 { link = "@type" })
hi("@lsp.type.class",                { fg = c.type })
hi("@lsp.type.enum",                 { fg = c.type })
hi("@lsp.type.interface",            { fg = c.type })
hi("@lsp.type.struct",               { fg = c.type })
hi("@lsp.type.typeParameter",        { fg = c.type_param })
hi("@lsp.type.parameter",            { link = "@parameter" })
hi("@lsp.type.variable",             { link = "@variable" })
hi("@lsp.type.property",             { link = "@property" })
hi("@lsp.type.enumMember",           { fg = c.constant, italic = true })
hi("@lsp.type.event",                { fg = c.func })
hi("@lsp.type.function",             { link = "@function" })
hi("@lsp.type.method",               { link = "@function.method" })
hi("@lsp.type.macro",                { link = "@keyword" })
hi("@lsp.type.keyword",              { link = "@keyword" })
hi("@lsp.type.modifier",             { fg = c.storage })
hi("@lsp.type.comment",              { link = "@comment" })
hi("@lsp.type.string",               { link = "@string" })
hi("@lsp.type.number",               { link = "@number" })
hi("@lsp.type.regexp",               { link = "@string.regexp" })
hi("@lsp.type.operator",             { link = "@operator" })
hi("@lsp.type.decorator",            { fg = c.decorator })
hi("@lsp.type.selfKeyword",          { fg = c.this_self })
hi("@lsp.type.builtinType",          { fg = c.keyword })
hi("@lsp.type.lifetime",             { fg = c.type_param })
hi("@lsp.mod.static",                { italic = true })
hi("@lsp.mod.deprecated",            { strikethrough = true })
hi("@lsp.typemod.variable.readonly", { fg = c.constant, italic = true })

-- GitSigns -----------------------------------------------------------
hi("GitSignsAdd",          { fg = c.git_add })
hi("GitSignsChange",       { fg = c.git_change })
hi("GitSignsDelete",       { fg = c.git_delete })
hi("GitSignsAddInline",    { bg = c.git_add, fg = c.bg })
hi("GitSignsChangeInline", { bg = c.git_change, fg = c.bg })
hi("GitSignsDeleteInline", { bg = c.git_delete, fg = c.bg })

-- Telescope ----------------------------------------------------------
hi("TelescopeNormal",          { fg = c.fg, bg = c.ui_subtle_bg })
hi("TelescopeBorder",          { fg = c.ui_input_border, bg = c.ui_subtle_bg })
hi("TelescopePromptNormal",    { fg = c.fg, bg = c.ui_input_bg })
hi("TelescopePromptBorder",    { fg = c.ui_input_border, bg = c.ui_input_bg })
hi("TelescopePromptTitle",     { fg = c.bg, bg = c.func, bold = true })
hi("TelescopePromptPrefix",    { fg = c.func, bg = c.ui_input_bg })
hi("TelescopeResultsTitle",    { fg = c.ui_subtle_bg, bg = c.ui_subtle_bg })
hi("TelescopePreviewTitle",    { fg = c.bg, bg = c.string, bold = true })
hi("TelescopeSelection",       { fg = c.fg, bg = c.selection })
hi("TelescopeMatching",        { fg = c.func, bold = true })

-- WhichKey -----------------------------------------------------------
hi("WhichKey",                 { fg = c.func })
hi("WhichKeyGroup",            { fg = c.type })
hi("WhichKeyDesc",             { fg = c.fg })
hi("WhichKeySeparator",        { fg = c.comment })
hi("WhichKeyFloat",            { bg = c.ui_subtle_bg })
hi("WhichKeyBorder",           { fg = c.ui_input_border, bg = c.ui_subtle_bg })

-- Diff ---------------------------------------------------------------
hi("DiffAdd",     { bg = "#E2F4DE" })
hi("DiffChange",  { bg = "#E0E9F8" })
hi("DiffDelete",  { bg = "#F8E0E0" })
hi("DiffText",    { bg = "#C9D7F4" })

-- Oil ----------------------------------------------------------------
hi("OilDir",       { fg = c.link, bold = true })
hi("OilFile",      { fg = c.fg })
hi("OilLink",      { fg = c.func })
hi("OilLinkTarget",{ fg = c.comment })
