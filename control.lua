local global = {}
local const INDEX_ITEM_PER_SEC = 1
local const INDEX_ITEM_PER_MIN = 2
local const INDEX_ITEM_PER_HOUR = 3

script.on_init(function()
    create_global_tables()
end)
script.on_configuration_changed(function()
    create_global_tables()
    global.entity_blacklist = {
        "se-delivery-cannon",
        "se-delivery-cannon-weapon",
        "se-energy-transmitter-emitter",
        "se-energy-transmitter-injector",
        "se-nexus",
    }

    local entity_blacklist_str = tostring(settings.startup["acr-blacklist"].value)

    --remove all spaces in the string, people are bad at reading and might put spaces after the comma
    entity_blacklist_str = entity_blacklist_str:gsub("%s+", "")

    --and then split the string with commans and add each prototype-name to it's own blacklist
    for prototype_name in string.gmatch(entity_blacklist_str, '([^,]+)') do
        table.insert(global.entity_blacklist, prototype_name)
    end
end)

function create_global_tables()
    if not global.gui_data_by_player            then global.gui_data_by_player = {}            end
    if not global.gui_data_by_player_persistent then global.gui_data_by_player_persistent = {} end
    if not global.entity_blacklist              then global.entity_blacklist = {} end
end

-- should we make a GUI for this entity?
function is_valid_gui_entity(entity)
    -- first we check the type of entity, most things should not have the GUI
    if not (entity.type == "assembling-machine" or entity.type == "furnace") then return false end

    -- then, we check the entity name against the blacklist
    for _, blacklist_name in pairs(global.entity_blacklist) do
        if entity.name == blacklist_name then return false end
    end

    -- and if both those checks succeed then it is a valid entity
    return true
end

script.on_event(defines.events.on_gui_opened, function(event)
    if event.gui_type == defines.gui_type.entity then
        if is_valid_gui_entity(event.entity) then
            local player = game.get_player(event.player_index)
            create_assembler_rate_gui(player, event.entity)
        end
    end
end)

script.on_event(defines.events.on_gui_closed, function(event)
    if event.gui_type == defines.gui_type.entity then
        if is_valid_gui_entity(event.entity) then
            local player = game.get_player(event.player_index)
            destroy_assembler_rate_gui(player, event.entity)
        end
    end
end)

script.on_event(defines.events.on_gui_click, function(event)
    local gui_data = global.gui_data_by_player[event.player_index]
    if gui_data then
        local clicked = nil
        for k, button in ipairs(gui_data.button) do
            if event.element == button then 
                clicked = k
            end
        end

        if clicked then
            gui_data.button_state = clicked
            update_assembler_rate_gui(game.players[event.player_index], gui_data.entity)
        end
    end
end)

script.on_event(defines.events.on_tick, function(event)
    if not global.gui_data_by_player then return end
    -- if (event.tick % 4) ~= 0 then return end

    -- iterate through tracked entities, and update guis if a thing that affects crafting speed changes
    for player_index, gui_data in pairs(global.gui_data_by_player) do
        local player = game.get_player(player_index)
        local entity = gui_data.entity

        -- somehow the entity doesn't exist anymore or is invalid, get rid of the GUI
        -- stops factorio from shitting itself if something has gone wrong, in any case
        if entity == nil or not entity.valid then
            destroy_assembler_rate_gui(player, entity)
            goto continue
        end

        local update_gui = false
        local entity_recipe = get_recipe_name_safe(entity)
        
        if (
            entity_recipe ~= gui_data.last_recipe
            or entity.crafting_speed ~= gui_data.last_crafting_speed
            or entity.productivity_bonus ~= gui_data.last_productivity_bonus
        ) then 
            update_gui = true 
        end

        if update_gui then 
            update_assembler_rate_gui(player, entity)
        end

        ::continue::
    end
end)

-- do a little cleanup if a player gets removed
script.on_event(defines.events.on_player_removed, function(event)
    global.gui_data_by_player[event.player_index]            = nil
    global.gui_data_by_player_persistent[event.player_index] = nil
end)


function create_assembler_rate_gui(player, entity)
    -- we're going to need these, make them if they don't exist
    create_global_tables()

    -- and if for some reason the player already has old GUI data, destroy both the data and the
    -- GUI before attempting to create the new GUI
    if global.gui_data_by_player[player.index] then
        destroy_assembler_rate_gui(player, entity)
    end

    -- and just to be safe, we clean up old GUIs with the same name
    -- there can only be one, after all
    for _, gui in pairs(player.gui.relative.children) do
        if gui.name == "assembler-craft-rates-gui" then
            gui.destroy()
        end
    end

    -- the base frame, that everything goes into
    local gui_frame = player.gui.relative.add{type="frame", caption="Products", name="assembler-craft-rates-gui"}

    -- attach the new GUI to the correct machine type
    if entity.type == "assembling-machine" then
        gui_frame.anchor = {
            gui = defines.relative_gui_type.assembling_machine_gui,
            position = defines.relative_gui_position.right
        }
    elseif entity.type == "furnace" then
        gui_frame.anchor = {
            gui = defines.relative_gui_type.furnace_gui,
            position = defines.relative_gui_position.right
        }
    end

    local content_frame  = gui_frame.add{type="frame", style="inside_shallow_frame_with_padding"}
    local contents_flow  = content_frame.add{type="flow", direction="vertical"}

    -- the ingredient/product list gets it's own flow
    -- since we may need to rebuild this, and 
    -- it's useful to have a container to put stuff in
    -- we put stuff in here in the update stage
    local data_flow = contents_flow.add{type="flow", direction="vertical"}

    contents_flow.add{type="line"}

    -- and to do the controls
    local controls_flow = contents_flow.add{type="flow", direction="horizontal"}
    controls_flow.add{type="label", caption="Display as:"}
    controls_flow.style.vertical_align = "center"

    -- buttons get their own flow since they're a single group
    local controls_buttons_flow = controls_flow.add{type="flow", direction="horizontal"}
    controls_buttons_flow.style.horizontal_spacing = 0

    local controls_buttons = {}

    for k, label in ipairs({"items/s", "items/m", "items/h"}) do
        local new_button = controls_buttons_flow.add{type="button", caption=label}
        new_button.style.size = {70,22}
        new_button.style.padding = {0,0,0,0}
        controls_buttons[k] = new_button
    end

    -- if the persistent data table doesn't exist for a player, we create it here when the GUI is created
    if not global.gui_data_by_player_persistent[player.index] then
        global.gui_data_by_player_persistent[player.index] = {}
    end

    -- and we need to keep track of the entity, add it to a list
    local gui_data = {
        gui = gui_frame,
        data_flow = data_flow,
        button = controls_buttons,
        button_state = global.gui_data_by_player_persistent[player.index].button_state or INDEX_ITEM_PER_MIN,
        entity = entity
    }

    global.gui_data_by_player[player.index] = gui_data

    -- and now that we've done that we can run the update to populate everything that needs to change when things... change
    -- and yes, creating something for the first time is an update
    update_assembler_rate_gui(player, entity)
end

function update_assembler_rate_gui(player, entity)
    local gui_data = global.gui_data_by_player[player.index]
    local data_flow    = gui_data.data_flow
    local button_state = gui_data.button_state

    -- populate the list of ingredients/products
    data_flow.clear()
    local has_recipe = create_gui_list_ui(data_flow, entity, button_state)

    gui_data.gui.visible = has_recipe

    -- and whichever button is selected, radio-button style
    for k, button in ipairs(gui_data.button) do
        button.toggled = k == gui_data.button_state
    end

    -- oh and we need to keep track of what the last thing was so we know when to update things
    gui_data.last_recipe = get_recipe_name_safe(entity)
    gui_data.last_crafting_speed = entity.crafting_speed
    gui_data.last_productivity_bonus = entity.productivity_bonus

    -- and while we're here, let's persist the player's button selection for when they open the GUI next
    -- this table never gets cleared unless the player gets removed
    global.gui_data_by_player_persistent[player.index].button_state = gui_data.button_state
end

-- creates the list of ingredients and products in the GUI
-- returns a boolean indicating if the entity had a valid recipe
function create_gui_list_ui(parent, entity, button_state)
    if get_recipe_name_safe(entity) then
        local recipe_ingredients, recipe_products = get_rate_data_for_entity(entity)

        if #recipe_ingredients > 0 or #recipe_products > 0 then
            -- we only need to make the list if there's ingredients in the recipes (some modded recipies have)
            -- (no ingredients, like K2's atmospheric condenser)
            if #recipe_ingredients > 0 then
                create_gui_list(parent, "Ingredients:", recipe_ingredients, button_state)
            end

            if #recipe_ingredients > 0 and #recipe_products > 0 then
                parent.add{type="line"}
            end

            -- and ditto for products (some mods have item void recipies, this makes them display properly)
            if #recipe_products > 0 then
                create_gui_list(parent, "Products:", recipe_products, button_state)
            end

            return true
        else
            local no_items_text = parent.add{type="label", caption="Curent recipe has no ingredients and no products"}

            return false
        end
    else
        local no_recipe_text = parent.add{type="label", caption="No recipe selected"}

        return false
    end
end

function create_gui_list(parent, label, item_data_list, button_state)
    local container = parent.add{type="flow", direction="vertical"}
    
    local header = container.add{type="label", caption=label}

    local flow_frame = container.add{type="frame", style="deep_frame_in_shallow_frame"}
    flow_frame.style.horizontally_stretchable = true
    flow_frame.style.padding = 5

    local flow = flow_frame.add{type="flow", direction="vertical"}

    for i = 1, #item_data_list do
        create_gui_list_entry(flow, item_data_list[i], button_state)
        if i < #item_data_list then
            flow.add{type="line", direction="horizontal"}
        end
    end

    return container
end

function create_gui_list_entry(parent, item_data, button_state)
    local data_name = nil
    local data_sprite = nil
    local button_state_lut = {
        {1,    "s"},
        {60,   "m"},
        {3600, "h"}
    }

    if item_data.type == "item" then
        data_name = prototypes.item[item_data.name].localised_name
        data_sprite = "item/" .. item_data.name
    elseif item_data.type == "fluid" then
        data_name = prototypes.fluid[item_data.name].localised_namesaa
        data_sprite = "fluid/" .. item_data.name
    else
        return
    end

    local flow = parent.add{type="flow", direction="horizontal"}
    flow.style.vertical_align = "center"

    local rate = flow.add{type="label"}
    rate.caption = format_gui_list_entry_rate(
        item_data.rate * button_state_lut[button_state][1],
        button_state_lut[button_state][2]
    )
    rate.style.width = 70
    rate.style.horizontal_align = "right"
    rate.style.padding = 2

    local line = flow.add{type="line", direction = "vertical"}
    line.style.vertically_stretchable = false
    line.style.height = 32
    
    local sprite = flow.add{type="sprite", sprite=data_sprite}
    
    local label = flow.add{type="label", caption=data_name}
    label.style.padding = 2
end

function format_gui_list_entry_rate(rate, postfix)
    local suffixes = {'','k','M','G','T','P'}
    local exponent = math.floor(math.log(rate) / math.log(10))

    exponent_rounded = math.floor(exponent / 3) * 3
    exponent_rounded = math.max(exponent_rounded, 0)
    exponent_rounded = math.min(exponent_rounded, 15)
    local rate_scaled = rate / 10^exponent_rounded

    local fstring = "%s%s/%s"

    local rate_precision = 1
    if exponent > 0 then
            -- percision will always be whatever gives us 4 significant figures, for anything above 1/timeunit
        local significant_figures = 4
        rate_precision = ((significant_figures-1) - exponent%(significant_figures-1))
    else
        rate_precision = 3
    end

    -- https://stackoverflow.com/questions/24697848/strip-trailing-zeroes-and-decimal-point
    local rate_string = string.format(" %."..rate_precision.."f", rate_scaled):gsub("%.?0+$", "")

    return string.format(
        fstring,
        rate_string,
        suffixes[(exponent_rounded/3)+1],
        postfix
    )

end

function destroy_assembler_rate_gui(player, entity)
    if not global.gui_data_by_player[player.index] then return end

    --we don't need to track the associated entity anymore, remove it from the list
    if global.gui_data_by_player[player.index].gui then
        global.gui_data_by_player[player.index].gui.destroy()
    end

    global.gui_data_by_player[player.index] = nil
end

function get_rate_data_for_entity(entity)
    -- done instead of entity.recipe() since this does null checking and returns previous furnace recipies
    local recipe = entity.get_recipe()
    if recipe == nil then return {}, {} end

    local out_ingredients = {}
    local out_products = {}

    local crafts_per_second = entity.crafting_speed/recipe.energy

    for _, ingredient in pairs(recipe.ingredients) do
        table.insert(out_ingredients,
            {
                type = ingredient.type,
                name = ingredient.name,
                rate = ingredient.amount * crafts_per_second
            }
        )
    end

    for _, product in pairs(recipe.products) do
        local product_min = 0
        local product_max = 0
        local product_probability = product.probability or 1

        local bonus_product = 0
        local bonus_multiplier = entity.productivity_bonus

        if product.amount then
            product_min = product.amount
            product_max = product.amount
        elseif product.amount_min and product.amount_max then
            product_min = product.amount_min
            product_max = product.amount_max
        end

        if entity.productivity_bonus > 0 then
            local amount_without_productivity = product.catalyst_amount or 0

            if amount_without_productivity <= product_min then
                bonus_product = ((product_min + product_max)/2 - amount_without_productivity)
            elseif product_min < amount_without_productivity and amount_without_productivity < product_max then
                -- find the range of possible bonus product values 
                -- (min is always 1, since there must be some value where you will get one bonus product)
                -- then find the percentages of rolls that will produce an extra productivity item
                local prod_max = product_max - amount_without_productivity
                local prod_min = 1

                local prod_roll_weight = (product_max - amount_without_productivity) / (product_max-product_min+1)
                bonus_product = (prod_max + prod_min)/2 * prod_roll_weight
            elseif amount_without_productivity >= product_max then
                bonus_product = 0
            end
        end

        local expected_product = ((product_min + product_max)/2 + bonus_product*bonus_multiplier)*product_probability
        
        -- some mods have item voids that use a recipe with a 0% chance to return products
        -- we don't want to return a product for a dummy void item
        if expected_product > 0 then
            table.insert(out_products,
                {
                    type = product.type,
                    name = product.name,
                    rate = expected_product * crafts_per_second
                }
            )
        end
    end

    return out_ingredients, out_products
end

-- safe way of getting the name of a recipe
-- will return the name of the recipe, or nil if no recipe is set
-- in the case of a furnace, will also check the previous recipe
function get_recipe_name_safe(entity)
    local recipe_name = entity.get_recipe() and entity.get_recipe().name or nil

    if recipe_name == nil and entity.type == "furnace" then
        recipe_name = entity.previous_recipe and entity.previous_recipe.name or nil
    end

    return recipe_name
end