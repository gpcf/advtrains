--trainlogic.lua
--controls train entities stuff about connecting/disconnecting/colliding trains and other things


local benchmark=false
local bm={}
local bmlt=0
local bmsteps=0
local bmstepint=200
printbm=function(action, ta)
	if not benchmark then return end
	local t=(os.clock()-ta)*1000
	if not bm[action] then
		bm[action]=t
	else
		bm[action]=bm[action]+t
	end
	bmlt=bmlt+t
end
function endstep()
	if not benchmark then return end
	bmsteps=bmsteps-1
	if bmsteps<=0 then
		bmsteps=bmstepint
		for key, value in pairs(bm) do
			minetest.chat_send_all(key.." "..(value/bmstepint).." ms avg.")
		end
		minetest.chat_send_all("Total time consumed by all advtrains actions per step: "..(bmlt/bmstepint).." ms avg.")
		bm={}
		bmlt=0
	end
end

advtrains.train_accel_force=2--per second and divided by number of wagons
advtrains.train_brake_force=3--per second, not divided by number of wagons
advtrains.train_roll_force=0.5--per second, not divided by number of wagons, acceleration when rolling without brake
advtrains.train_emerg_force=10--for emergency brakes(when going off track)

advtrains.audit_interval=30


advtrains.trains={}
advtrains.wagon_save={}

--load initially
advtrains.fpath=minetest.get_worldpath().."/advtrains"
local file, err = io.open(advtrains.fpath, "r")
if not file then
	local er=err or "Unknown Error"
	print("[advtrains]Failed loading advtrains save file "..er)
else
	local tbl = minetest.deserialize(file:read("*a"))
	if type(tbl) == "table" then
		advtrains.trains=tbl
	end
	file:close()
end
advtrains.fpath_ws=minetest.get_worldpath().."/advtrains_wagon_save"
local file, err = io.open(advtrains.fpath_ws, "r")
if not file then
	local er=err or "Unknown Error"
	print("[advtrains]Failed loading advtrains save file "..er)
else
	local tbl = minetest.deserialize(file:read("*a"))
	if type(tbl) == "table" then
		advtrains.wagon_save=tbl
	end
	file:close()
end


advtrains.save = function()
	--print("[advtrains]saving")
	advtrains.invalidate_all_paths()
	local datastr = minetest.serialize(advtrains.trains)
	if not datastr then
		minetest.log("error", "[advtrains] Failed to serialize train data!")
		return
	end
	local file, err = io.open(advtrains.fpath, "w")
	if err then
		return err
	end
	file:write(datastr)
	file:close()
	
	-- update wagon saves
	for _,wagon in pairs(minetest.luaentities) do
		if wagon.is_wagon and wagon.initialized then
			wagon:get_staticdata()
		end
	end
	--cross out userdata
	for w_id, data in pairs(advtrains.wagon_save) do
		data.name=nil
		data.object=nil
		if data.driver then
			data.driver_name=data.driver:get_player_name()
			data.driver=nil
		else
			data.driver_name=nil
		end
		if data.discouple then
			data.discouple.object:remove()
			data.discouple=nil
		end
	end
	--print(dump(advtrains.wagon_save))
	datastr = minetest.serialize(advtrains.wagon_save)
	if not datastr then
		minetest.log("error", "[advtrains] Failed to serialize train data!")
		return
	end
	file, err = io.open(advtrains.fpath_ws, "w")
	if err then
		return err
	end
	file:write(datastr)
	file:close()
	
	advtrains.save_trackdb()
end
minetest.register_on_shutdown(advtrains.save)

advtrains.save_and_audit_timer=advtrains.audit_interval
minetest.register_globalstep(function(dtime)
	advtrains.save_and_audit_timer=advtrains.save_and_audit_timer-dtime
	if advtrains.save_and_audit_timer<=0 then
		local t=os.clock()
		
		--save
		advtrains.save()
		advtrains.save_and_audit_timer=advtrains.audit_interval
		printbm("saving", t)
	end
	--regular train step
	local t=os.clock()
	for k,v in pairs(advtrains.trains) do
		advtrains.train_step(k, v, dtime)
	end
	
	--see tracks.lua
	if advtrains.detector.clean_step_before then
		advtrains.detector.finalize_restore()
	end
	
	printbm("trainsteps", t)
	endstep()
end)

function advtrains.train_step(id, train, dtime)
	--Legacy: set drives_on and max_speed
	if not train.drives_on or not train.max_speed then
		advtrains.update_trainpart_properties(id)
	end
	--TODO check for all vars to be present
	if not train.velocity then
		train.velocity=0
	end
	if not train.movedir or (train.movedir~=1 and train.movedir~=-1) then
		train.movedir=1
	end
	--very unimportant thing: check if couple is here
	if train.couple_eid_front and (not minetest.luaentities[train.couple_eid_front] or not minetest.luaentities[train.couple_eid_front].is_couple) then train.couple_eid_front=nil end
	if train.couple_eid_back and (not minetest.luaentities[train.couple_eid_back] or not minetest.luaentities[train.couple_eid_back].is_couple) then train.couple_eid_back=nil end
	
	--skip certain things (esp. collision) when not moving
	local train_moves=(train.velocity~=0)
	
	--if not train.last_pos then advtrains.trains[id]=nil return end
	
	if not advtrains.pathpredict(id, train) then 
		print("pathpredict failed(returned false)")
		train.velocity=0
		train.tarvelocity=0
		return
	end
	
	local path=advtrains.get_or_create_path(id, train)
	if not path then
		train.velocity=0
		train.tarvelocity=0
		print("train has no path for whatever reason")
		return 
	end
	
	local train_end_index=advtrains.get_train_end_index(train)
	--apply off-track handling:
	local front_off_track=train.max_index_on_track and train.index>train.max_index_on_track
	local back_off_track=train.min_index_on_track and train_end_index<train.min_index_on_track
	if front_off_track and back_off_track then--allow movement in both directions
		if train.tarvelocity>1 then train.tarvelocity=1 end
	elseif front_off_track then--allow movement only backward
		if train.movedir==1 and train.tarvelocity>0 then train.tarvelocity=0 end
		if train.movedir==-1 and train.tarvelocity>1 then train.tarvelocity=1 end
	elseif back_off_track then--allow movement only forward
		if train.movedir==-1 and train.tarvelocity>0 then train.tarvelocity=0 end
		if train.movedir==1 and train.tarvelocity>1 then train.tarvelocity=1 end
	end
	
	--update advtrains.detector
	if not train.detector_old_index then
		train.detector_old_index = math.floor(train_end_index)
		train.detector_old_end_index = math.floor(train_end_index)
	end
	local ifo, ifn, ibo, ibn = train.detector_old_index, math.floor(train.index), train.detector_old_end_index, math.floor(train_end_index)
	if ifn>ifo then
		for i=ifo, ifn do
			if path[i] then
				advtrains.detector.enter_node(path[i], id)
			end
		end
	elseif ifn<ifo then
		for i=ifn, ifo do
			if path[i] then
				advtrains.detector.leave_node(path[i], id)
			end
		end
	end
	if ibn<ibo then
		for i=ibn, ibn do
			if path[i] then
				advtrains.detector.enter_node(path[i], id)
			end
		end
	elseif ibn>ibo then
		for i=ibo, ibn do
			if path[i] then
				advtrains.detector.leave_node(path[i], id)
			end
		end
	end
	train.detector_old_index = math.floor(train.index)
	train.detector_old_end_index = math.floor(train_end_index)
	
	--remove?
	if #train.trainparts==0 then
		print("[advtrains][train "..sid(id).."] has empty trainparts, removing.")
		advtrains.detector.leave_node(path[train.detector_old_index], id)
		advtrains.trains[id]=nil
		return
	end
	
	if train_moves then
		--check for collisions by finding objects
		
		--heh, new collision again.
		--this time, based on NODES and the advtrains.detector.on_node table.
		local collpos
		local coll_grace=1
		if train.movedir==1 then
			collpos=advtrains.get_real_index_position(path, train.index-coll_grace)
		else
			collpos=advtrains.get_real_index_position(path, train_end_index+coll_grace)
		end
		if collpos then
			local rcollpos=advtrains.round_vector_floor_y(collpos)
			for x=-1,1 do
				for z=-1,1 do
					local testpos=vector.add(rcollpos, {x=x, y=0, z=z})
					local testpts=minetest.pos_to_string(testpos)
					if advtrains.detector.on_node[testpts] and advtrains.detector.on_node[testpts]~=id then
						--collides
						advtrains.spawn_couple_on_collide(id, testpos, advtrains.detector.on_node[testpts], train.movedir==-1)
						
						train.recently_collided_with_env=true
						train.velocity=0.5*train.velocity
						train.movedir=train.movedir*-1
						train.tarvelocity=0
						
					end
				end
			end
		end
	end
	--check for any trainpart entities if they have been unloaded. do this only if train is near a player, to not spawn entities into unloaded areas
	--todo function will be taken by update_trainpart_properties
	train.check_trainpartload=(train.check_trainpartload or 0)-dtime
	local node_range=(math.max((minetest.setting_get("active_block_range") or 0),1)*16)
	if train.check_trainpartload<=0 then
		local ori_pos=advtrains.get_real_index_position(path, train.index) --not much to calculate
		--print("[advtrains][train "..id.."] at "..minetest.pos_to_string(vector.round(ori_pos)))
		
		local should_check=false
		for _,p in ipairs(minetest.get_connected_players()) do
			should_check=should_check or ((vector.distance(ori_pos, p:getpos())<node_range))
		end
		if should_check then
			advtrains.update_trainpart_properties(id)
		end
		train.check_trainpartload=2
	end
	
	
	--handle collided_with_env
	if train.recently_collided_with_env then
		train.tarvelocity=0
		if not train_moves then
			train.recently_collided_with_env=false--reset status when stopped
		end
	end
	if train.locomotives_in_train==0 then
		train.tarvelocity=0
	end
	--make brake adjust the tarvelocity if necessary
	if train.brake and (math.ceil(train.velocity)-1)<train.tarvelocity then
		train.tarvelocity=math.max((math.ceil(train.velocity)-1), 0)
	end
	--apply tarvel(but with physics in mind!)
	if train.velocity~=train.tarvelocity then
		local applydiff=0
		local mass=#train.trainparts
		local diff=train.tarvelocity-train.velocity
		if diff>0 then--accelerating, force will be brought on only by locomotives.
			--print("accelerating with default force")
			applydiff=(math.min((advtrains.train_accel_force*train.locomotives_in_train*dtime)/mass, math.abs(diff)))
		else--decelerating
			if front_off_track or back_off_track or train.recently_collided_with_env then --every wagon has a brake, so not divided by mass.
				--print("braking with emergency force")
				applydiff= -(math.min((advtrains.train_emerg_force*dtime), math.abs(diff)))
			elseif train.brake then
				--print("braking with default force")
				--no math.min, because it can grow beyond tarvelocity, see up there
				--dont worry, it will never fall below zero.
				applydiff= -((advtrains.train_brake_force*dtime))
			else
				--print("roll")
				applydiff= -(math.min((advtrains.train_roll_force*dtime), math.abs(diff)))
			end
		end
		train.last_accel=(applydiff*train.movedir)
		train.velocity=math.min(math.max( train.velocity+applydiff , 0), train.max_speed or 10)
	else
		train.last_accel=0
	end
	
	--move
	--TODO 3,5 + 0.7
	train.index=train.index and train.index+(((train.velocity*train.movedir)/(train.path_dist[math.floor(train.index)] or 1))*dtime) or 0
	
end


--structure of train table:
--[[
trains={
	[train_id]={
		trainparts={
			[n]=wagon_id
		}
		path={path}
		velocity
		tarvelocity
		index
		trainlen
		path_inv_level
		last_pos       |
		last_dir       | for pathpredicting.
	}
}
--a wagon itself has the following properties:
wagon={
	unique_id
	train_id
	pos_in_train (is index difference, including train_span stuff)
	pos_in_trainparts (is index in trainparts tabel of trains)
}
inherited by metatable:
wagon_proto={
	wagon_span
}
]]

--returns new id
function advtrains.create_new_train_at(pos, pos_prev)
	local newtrain_id=os.time()..os.clock()
	while advtrains.trains[newtrain_id] do newtrain_id=os.time()..os.clock() end--ensure uniqueness(will be unneccessary)
	
	advtrains.trains[newtrain_id]={}
	advtrains.trains[newtrain_id].last_pos=pos
	advtrains.trains[newtrain_id].last_pos_prev=pos_prev
	advtrains.trains[newtrain_id].tarvelocity=0
	advtrains.trains[newtrain_id].velocity=0
	advtrains.trains[newtrain_id].trainparts={}
	return newtrain_id
end

--returns false on failure. handle this case!
function advtrains.pathpredict(id, train)
	
	--print("pos ",x,y,z)
	--::rerun::
	if not train.index then train.index=0 end
	if not train.path or #train.path<2 then
		if not train.last_pos then
			--no chance to recover
			print("[advtrains]train hasn't saved last-pos, removing train.")
			advtrains.train[id]=nil
			return false
		end
		
		local node_ok=advtrains.get_rail_info_at(advtrains.round_vector_floor_y(train.last_pos), train.drives_on)
		
		if node_ok==nil then
			--block not loaded, do nothing
			return nil
		elseif node_ok==false then
			print("[advtrains]no track here, (fail) removing train.")
			advtrains.trains[id]=nil
			return false
		end
		
		if not train.last_pos_prev then
			--no chance to recover
			print("[advtrains]train hasn't saved last-pos_prev, removing train.")
			advtrains.trains[id]=nil
			return false
		end
		
		local prevnode_ok=advtrains.get_rail_info_at(advtrains.round_vector_floor_y(train.last_pos_prev), train.drives_on)
		
		if prevnode_ok==nil then
			--block not loaded, do nothing
			return nil
		elseif prevnode_ok==false then
			print("[advtrains]no track at prev, (fail) removing train.")
			advtrains.trains[id]=nil
			return false
		end
		
		train.index=(train.restore_add_index or 0)+(train.savedpos_off_track_index_offset or 0)
		--restore_add_index is set by save() to prevent trains hopping to next round index. should be between -0.5 and 0.5
		--savedpos_off_track_index_offset is set if train went off track. see below.
		train.path={}
		train.path_dist={}
		train.path[0]=train.last_pos
		train.path[-1]=train.last_pos_prev
		train.path_dist[-1]=vector.distance(train.last_pos, train.last_pos_prev)
	end
	
	local pregen_front=2
	local pregen_back=2
	if train.velocity>0 then
		if train.movedir>0 then
			pregen_front=2+math.ceil(train.velocity*0.15) --assumes server step of 0.1 seconds, +50% tolerance
		else
			pregen_back=2+math.ceil(train.velocity*0.15)
		end
	end
	
	
	local maxn=advtrains.maxN(train.path)
	while (maxn-train.index) < pregen_front do--pregenerate
		--print("[advtrains]maxn conway for ",maxn,minetest.pos_to_string(path[maxn]),maxn-1,minetest.pos_to_string(path[maxn-1]))
		local conway=advtrains.conway(train.path[maxn], train.path[maxn-1], train.drives_on)
		if conway then
			train.path[maxn+1]=conway
			train.max_index_on_track=maxn
		else
			--do as if nothing has happened and preceed with path
			--but do not update max_index_on_track
			--print("over-generating path max to index "..maxn+1)
			train.path[maxn+1]=vector.add(train.path[maxn], vector.subtract(train.path[maxn], train.path[maxn-1]))
		end
		train.path_dist[maxn]=vector.distance(train.path[maxn+1], train.path[maxn])
		maxn=advtrains.maxN(train.path)
	end
	
	local minn=advtrains.minN(train.path)
	while (train.index-minn) < (train.trainlen or 0) + pregen_back do --post_generate. has to be at least trainlen. (we let go of the exact calculation here since this would be unuseful here)
		--print("[advtrains]minn conway for ",minn,minetest.pos_to_string(path[minn]),minn+1,minetest.pos_to_string(path[minn+1]))
		local conway=advtrains.conway(train.path[minn], train.path[minn+1], train.drives_on)
		if conway then
			train.path[minn-1]=conway
			train.min_index_on_track=minn
		else
			--do as if nothing has happened and preceed with path
			--but do not update min_index_on_track
			--print("over-generating path min to index "..minn-1)
			train.path[minn-1]=vector.add(train.path[minn], vector.subtract(train.path[minn], train.path[minn+1]))
		end
		train.path_dist[minn-1]=vector.distance(train.path[minn], train.path[minn-1])
		minn=advtrains.minN(train.path)
	end
	if not train.min_index_on_track then train.min_index_on_track=0 end
	if not train.max_index_on_track then train.max_index_on_track=0 end
	
	--make pos/yaw available for possible recover calls
	if train.max_index_on_track<train.index then --whoops, train went too far. the saved position will be the last one that lies on a track, and savedpos_off_track_index_offset will hold how far to go from here
		train.savedpos_off_track_index_offset=train.index-train.max_index_on_track
		train.last_pos=train.path[train.max_index_on_track]
		train.last_pos_prev=train.path[train.max_index_on_track-1]
		--print("train is off-track (front), last positions kept at "..minetest.pos_to_string(train.last_pos).." / "..minetest.pos_to_string(train.last_pos_prev))
	elseif train.min_index_on_track+1>train.index then --whoops, train went even more far. same behavior
		train.savedpos_off_track_index_offset=train.index-train.min_index_on_track
		train.last_pos=train.path[train.min_index_on_track+1]
		train.last_pos_prev=train.path[train.min_index_on_track]
		--print("train is off-track (back), last positions kept at "..minetest.pos_to_string(train.last_pos).." / "..minetest.pos_to_string(train.last_pos_prev))
	else --regular case
		train.savedpos_off_track_index_offset=nil
		train.last_pos=train.path[math.floor(train.index+0.5)]
		train.last_pos_prev=train.path[math.floor(train.index-0.5)]
	end
	return train.path
end
function advtrains.get_train_end_index(train)
	return advtrains.get_real_path_index(train, train.trainlen or 2)--this function can be found inside wagons.lua since it's more related to wagons. we just set trainlen as pos_in_train
end

function advtrains.get_or_create_path(id, train)
	if not train.path then return advtrains.pathpredict(id, train) end
	return train.path
end

function advtrains.add_wagon_to_train(wagon, train_id, index)
	local train=advtrains.trains[train_id]
	if index then
		table.insert(train.trainparts, index, wagon.unique_id)
	else
		table.insert(train.trainparts, wagon.unique_id)
	end
	--this is not the usual case!!!
	--we may set initialized because the wagon has no chance to step()
	wagon.initialized=true
	--TODO is this art or can we throw it away?
	advtrains.update_trainpart_properties(train_id)
end
function advtrains.update_trainpart_properties(train_id, invert_flipstate)
	local train=advtrains.trains[train_id]
	train.drives_on=advtrains.all_tracktypes
	train.max_speed=100
	local rel_pos=0
	local count_l=0
	for i, w_id in ipairs(train.trainparts) do
		local wagon=nil
		for _,iwagon in pairs(minetest.luaentities) do
			if iwagon.is_wagon and iwagon.initialized and iwagon.unique_id==w_id then
				if wagon then
					--duplicate
					iwagon.object:remove()
				else
					wagon=iwagon
				end
			end
		end
		if not wagon then
			if advtrains.wagon_save[w_id] then
				--spawn a new and initialize it with the properties from wagon_save
				wagon=minetest.env:add_entity(train.last_pos, advtrains.wagon_save[w_id].entity_name):get_luaentity()
				wagon:init_from_wagon_save(w_id)
			end
		end
		if wagon then
			rel_pos=rel_pos+wagon.wagon_span
			wagon.train_id=train_id
			wagon.pos_in_train=rel_pos
			wagon.pos_in_trainparts=i
			wagon.old_velocity_vector=nil
			if wagon.is_locomotive then
				count_l=count_l+1
			end
			if invert_flipstate then
				wagon.wagon_flipped = not wagon.wagon_flipped
			end
			rel_pos=rel_pos+wagon.wagon_span
			any_loaded=true
			
			if wagon.drives_on then
				for k,_ in pairs(train.drives_on) do
					if not wagon.drives_on[k] then
						train.drives_on[k]=nil
					end
				end
			end
			train.max_speed=math.min(train.max_speed, wagon.max_speed)
		else
			print(w_id.." not loaded and no save available")
			--what the hell...
			table.remove(train.trainparts, pit)
		end
	end
	train.trainlen=rel_pos
	train.locomotives_in_train=count_l
end

function advtrains.split_train_at_wagon(wagon)
	--get train
	local train=advtrains.trains[wagon.train_id]
	local real_pos_in_train=advtrains.get_real_path_index(train, wagon.pos_in_train)
	local pos_for_new_train=advtrains.get_or_create_path(wagon.train_id, train)[math.floor(real_pos_in_train+wagon.wagon_span)]
	local pos_for_new_train_prev=advtrains.get_or_create_path(wagon.train_id, train)[math.floor(real_pos_in_train-1+wagon.wagon_span)]
	
	--before doing anything, check if both are rails. else do not allow
	if not pos_for_new_train then
		print("split_train: pos_for_new_train not set")
		return false
	end
	local node_ok=advtrains.get_rail_info_at(advtrains.round_vector_floor_y(pos_for_new_train), train.drives_on)
	if not node_ok then
		print("split_train: pos_for_new_train "..minetest.pos_to_string(advtrains.round_vector_floor_y(pos_for_new_train_prev)).." not loaded or is not a rail")
		return false
	end
	
	if not train.last_pos_prev then
		print("split_train: pos_for_new_train_prev not set")
		return false
	end
	
	local prevnode_ok=advtrains.get_rail_info_at(advtrains.round_vector_floor_y(pos_for_new_train), train.drives_on)
	if not prevnode_ok then
		print("split_train: pos_for_new_train_prev "..minetest.pos_to_string(advtrains.round_vector_floor_y(pos_for_new_train_prev)).." not loaded or is not a rail")
		return false
	end
	
	--create subtrain
	local newtrain_id=advtrains.create_new_train_at(pos_for_new_train, pos_for_new_train_prev)
	local newtrain=advtrains.trains[newtrain_id]
	--insert all wagons to new train
	for k,v in ipairs(train.trainparts) do
		if k>=wagon.pos_in_trainparts then
			table.insert(newtrain.trainparts, v)
			train.trainparts[k]=nil
		end
	end
	--update train parts
	advtrains.update_trainpart_properties(wagon.train_id)--atm it still is the desierd id.
	advtrains.update_trainpart_properties(newtrain_id)
	train.tarvelocity=0
	newtrain.velocity=train.velocity
	newtrain.tarvelocity=0
end

--there are 4 cases:
--1/2. F<->R F<->R regular, put second train behind first
--->frontpos of first train will match backpos of second
--3.   F<->R R<->F flip one of these trains, take the other as new train
--->backpos's will match
--4.   R<->F F<->R flip one of these trains and take it as new parent
--->frontpos's will match

--true when trains are facing each other. needed on colliding.
-- check done by iterating paths and checking their direction
--returns nil when not on the same track at all OR when required path items are not generated. this distinction may not always be needed.
function advtrains.trains_facing(train1, train2)
	local sr_pos=train1.path[math.floor(train1.index)]
	local sr_pos_p=train1.path[math.floor(train1.index)-1]

	for i=advtrains.minN(train2.path), advtrains.maxN(train2.path) do
		if vector.equals(sr_pos, train2.path[i]) then
			if train2.path[i+1] and vector.equals(sr_pos_p, train2.path[i+1]) then return true end
			if train2.path[i-1] and vector.equals(sr_pos_p, train2.path[i-1]) then return false end
			return nil
		end
	end
	return nil
end

function advtrains.spawn_couple_on_collide(id1, pos, id2, t1_is_backpos)
	print("COLLISION: "..sid(id1).." and "..sid(id2).." at "..minetest.pos_to_string(pos)..", t1_is_backpos="..(t1_is_backpos and "true" or "false"))
	--TODO:
	local train1=advtrains.trains[id1]
	local train2=advtrains.trains[id2]
	
	local found
	for i=advtrains.minN(train1.path), advtrains.maxN(train1.path) do
		if vector.equals(train1.path[i], pos) then
			found=true
		end
	end
	if not found then
		print("Err: pos not in path")
		return 
	end
	
	local frontpos2=train2.path[math.floor(train2.detector_old_index)]
	local backpos2=train2.path[math.floor(train2.detector_old_end_index)]
	local t2_is_backpos
	print("End positions: "..minetest.pos_to_string(frontpos2)..minetest.pos_to_string(backpos2))
	
	if vector.equals(frontpos2, pos) then
		t2_is_backpos=false
	elseif vector.equals(backpos2, pos) then
		t2_is_backpos=true
	else
		print("Err: not a endpos")
		return --the collision position is not the end position.
	end
	print("t2_is_backpos="..(t2_is_backpos and "true" or "false"))
	
	local t1_has_couple
	if t1_is_backpos then
		t1_has_couple=train1.couple_eid_back
	else
		t1_has_couple=train1.couple_eid_front
	end
	local t2_has_couple
	if t2_is_backpos then
		t2_has_couple=train2.couple_eid_back
	else
		t2_has_couple=train2.couple_eid_front
	end
	
	if t1_has_couple then
		if minetest.object_refs[t1_has_couple] then minetest.object_refs[t1_has_couple]:remove() end
	end
	if t2_has_couple then
		if minetest.object_refs[t2_has_couple] then minetest.object_refs[t2_has_couple]:remove() end
	end
	local obj=minetest.add_entity(pos, "advtrains:couple")
	if not obj then print("failed creating object") return end
	local le=obj:get_luaentity()
	le.train_id_1=id1
	le.train_id_2=id2
	le.train1_is_backpos=t1_is_backpos
	le.train2_is_backpos=t2_is_backpos
	--find in object_refs
	for aoi, compare in pairs(minetest.object_refs) do
		if compare==obj then
			if t1_is_backpos then
				train1.couple_eid_back=aoi
			else
				train1.couple_eid_front=aoi
			end
			if t2_is_backpos then
				train2.couple_eid_back=aoi
			else
				train2.couple_eid_front=aoi
			end
		end
	end
	print("Couple entity:"..dump(le))
	
	--also TODO: integrate check_trainpartload into update_trainpart_properties. 
end
--order of trains may be irrelevant in some cases. check opposite cases. TODO does this work?
--pos1 and pos2 are just needed to form a median.


function advtrains.do_connect_trains(first_id, second_id)
	local first_wagoncnt=#advtrains.trains[first_id].trainparts
	local second_wagoncnt=#advtrains.trains[second_id].trainparts
	
	for _,v in ipairs(advtrains.trains[second_id].trainparts) do
		table.insert(advtrains.trains[first_id].trainparts, v)
	end
	--kick it like physics (with mass being #wagons)
	local new_velocity=((advtrains.trains[first_id].velocity*first_wagoncnt)+(advtrains.trains[second_id].velocity*second_wagoncnt))/(first_wagoncnt+second_wagoncnt)
	advtrains.trains[second_id]=nil
	advtrains.update_trainpart_properties(first_id)
	advtrains.trains[first_id].velocity=new_velocity
	advtrains.trains[first_id].tarvelocity=0
end

function advtrains.invert_train(train_id)
	local train=advtrains.trains[train_id]
	
	local old_path=advtrains.get_or_create_path(train_id, train)
	train.path={}
	train.index= - advtrains.get_train_end_index(train)
	train.velocity=-train.velocity
	train.tarvelocity=-train.tarvelocity
	for k,v in pairs(old_path) do
		train.path[-k]=v
	end
	local old_trainparts=train.trainparts
	train.trainparts={}
	for k,v in ipairs(old_trainparts) do
		table.insert(train.trainparts, 1, v)--notice insertion at first place
	end
	advtrains.update_trainpart_properties(train_id, true)
end

function advtrains.is_train_at_pos(pos)
	--print("istrainat: pos "..minetest.pos_to_string(pos))
	local checked_trains={}
	local objrefs=minetest.get_objects_inside_radius(pos, 2)
	for _,v in pairs(objrefs) do
		local le=v:get_luaentity()
		if le and le.is_wagon and le.initialized and le.train_id and not checked_trains[le.train_id] then
			--print("istrainat: checking "..le.train_id)
			checked_trains[le.train_id]=true
			local path=advtrains.get_or_create_path(le.train_id, le:train())
			if path then
				--print("has path")
				for i=math.floor(advtrains.get_train_end_index(le:train())+0.5),math.floor(le:train().index+0.5) do
					if path[i] then
						--print("has pathitem "..i.." "..minetest.pos_to_string(path[i]))
						if vector.equals(advtrains.round_vector_floor_y(path[i]), pos) then
							return true
						end
					end
				end
			end
		end
	end
	return false
end
function advtrains.invalidate_all_paths()
	--print("invalidating all paths")
	for k,v in pairs(advtrains.trains) do
		if v.index then
			v.restore_add_index=v.index-math.floor(v.index+0.5)
		end
		v.path=nil
		v.path_dist=nil
		v.index=nil
		v.min_index_on_track=nil
		v.max_index_on_track=nil
		
		advtrains.detector.setup_restore()
		v.detector_old_index=nil
		v.detector_old_end_index=nil
	end
end

--not blocking trains group
function advtrains.train_collides(node)
	if node and minetest.registered_nodes[node.name] and minetest.registered_nodes[node.name].walkable then
		if not minetest.registered_nodes[node.name].groups.not_blocking_trains then
			return true
		end
	end
	return false
end

local nonblocknodes={
	"default:fence_wood",
	"default:fence_acacia_wood",
	"default:fence_aspen_wood",
	"default:fence_pine_wood",
	"default:fence_junglewood",
	"default:torch",
	
	"default:sign_wall",
	"signs:sign_wall",
	"signs:sign_wall_blue",
	"signs:sign_wall_brown",
	"signs:sign_wall_orange",
	"signs:sign_wall_green",
	"signs:sign_yard",
	"signs:sign_wall_white_black",
	"signs:sign_wall_red",
	"signs:sign_wall_white_red",
	"signs:sign_wall_yellow",
	"signs:sign_post",
	"signs:sign_hanging",
	
	
}
minetest.after(0, function()
	for _,name in ipairs(nonblocknodes) do
		if minetest.registered_nodes[name] then
			minetest.registered_nodes[name].groups.not_blocking_trains=1
		end
	end
end)
