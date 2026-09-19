local path = assert(vim.env.SPRITE_SOURCE, "SPRITE_SOURCE is required for protocol integration")
local fixture_path = path .. "/tests/fixtures/surface-list-v1.json"
local file = assert(io.open(fixture_path, "r"), "Sprite protocol fixture is missing")
local fixture = vim.json.decode(file:read("*a"))
file:close()
local local_fixture =
  vim.json.decode(table.concat(vim.fn.readfile("tests/fixtures/surface-list-v1.json"), "\n"))
assert(
  vim.deep_equal(fixture, local_fixture),
  "local protocol fixture differs from Sprite's committed fixture"
)
local Fake = dofile("tests/fake_sprite.lua")
assert(fixture.version == 1)
assert(fixture.capabilities.request.type == "capabilities")
assert(fixture.capabilities.reply.eligible == true)
assert(fixture.description.root.kind == "virtual_list")
local state = { row_height = fixture.description.root.row_height }
for _, operation in ipairs(fixture.operations) do
  local accepted = Fake.validate(operation.request, state)
  assert((accepted == true) == (operation.reply.type == "applied"), operation.request.type)
end
print("Sprite committed protocol fixture parsed and validated")
