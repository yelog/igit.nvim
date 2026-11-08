if vim.g.loaded_igit then
  return
end
vim.g.loaded_igit = true

if vim.fn.has("nvim-0.10") == 1 then
  require("igit")._register_commands()
end
