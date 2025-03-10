--[[
Resolve cross-references to NixOS options in a hacky way and link them to the
unstable channel's option search page on search.nixos.org
]]

function Link(elem)
  prefix = '#opt-'
  if elem.target:sub(1, #prefix) == prefix then
    option_name = elem.target:sub(#prefix + 1)
    option_name = option_name:gsub('%._name_%.', '.<name>.')
    option_name = option_name:gsub('%._%.', '.*.')

    elem.target = 'https://search.nixos.org/options?channel=unstable&show=' .. option_name .. '&query=' .. option_name

    if #elem.content == 0 or (#elem.content == 1 and elem.content[1].tag == 'Str' and elem.content[1].text == '???') then
      elem.content = option_name
    end

    return elem
  end
end
