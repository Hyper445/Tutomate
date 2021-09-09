module PuzzleScript::Engine

import String;
import List;
import Type;
import Set;
import IO;
import PuzzleScript::Checker;
import PuzzleScript::AST;
import PuzzleScript::Compiler;
import util::Eval;

int MAX_LOOPS = 20;

Level restart(Level level){	
	if (level.states[-1] != level.layers) level.states += [deep_copy(level.layers)];
	
	level.layers = deep_copy(level.checkpoint);
	return level;
}

Level undo(Level level){
	int index;
	if (level.layers == level.states[-1]) {
		index = -2;
	} else {
		index = -1;
	}
	
	if (!isEmpty(level.states)) {
		level.layers = level.states[index];
		level.states = level.states[0..index];
	}
	
	return level;
}

Level checkpoint(Level level){
	level.checkpoint = deep_copy(level.layers);
	return level;
}

bool is_last(Engine engine){
	return engine.index == size(engine.levels) - 1;
}

Engine change_level(Engine engine, int index){
	engine.current_level = engine.levels[index];
	engine.index = index;
	engine.win_keyword = false;
	engine.abort = false;
	engine.again = false;
	
	return engine;
}

list[str] update_objectdata(Level level){
	set[str] objs = {};
	for (Layer lyr <- level.layers){
		for (Line line <- lyr){
			objs += {x.name | Object x <- line};
		}
	}
	
	return toList(objs);
}

// this rotates a level 90 degrees clockwise
// [ [1, 2] , becomes [ [3, 1] ,
//   [3, 4] ]  			[4, 2] ]
// right matching becomes up matching
list[Layer] rotate_level(list[Layer] layers){
	list[Layer] new_layers = [];
	for (Layer layer <- layers){
		list[Line] new_layer = [[] | _ <- [0..size(layer[0])]];
		for (int i <- [0..size(layer[0])]){
			for (int j <- [0..size(layer)]){
				new_layer[i] += [layer[j][i]];
			}
		}
		
		new_layers += [[reverse(x) | Line x <- new_layer]];
	}
	
	return new_layers;
}

str format_replacement(str pattern, str replacement, list[Layer] layers) {
	return "
	'list[Layer] layers = <layers>;
	'if (<pattern> := layers) layers = <replacement>;
	'layers;
	'";
}

str format_pattern(str pattern, list[Layer] layers){
	return "
	'list[Layer] layers  = <layers>;
	'<pattern> := layers;
	'";
}

map[str, list[str]] directional_absolutes = (
	"right" : ["right", "left",  "down",  "up"], // >
	"left" :  ["left",  "right", "up",    "down"], // <
	"down":   ["down",  "up",    "left",  "right"], // v
	"up" :    ["up",    "down",  "right", "left" ] // ^
);

bool eval_pattern(str pattern, str relatives)
	=	eval(#bool, [EVAL_PRESET, relatives, pattern]).val;

list[str] ROTATION_ORDER = ["right", "up", "left", "down"];
tuple[Engine, Level] apply_rule(Engine engine, Level level, Rule rule){
	int loops = 0;
	list[Layer] layers = level.layers;
	bool changed = false;
	for (str dir <- ROTATION_ORDER){
		if (dir in rule.directions){
			str relatives = format_relatives(directional_absolutes[dir]);
			while (all(str pattern <- rule.left, eval_pattern(format_pattern(pattern, layers), relatives))){
				changed = true;
				int index = loops % size(rule.left);
				
				if (isEmpty(rule.right)){
					break;
				}
				
				layers = eval(#list[Layer], [EVAL_PRESET, relatives, format_replacement(rule.left[index], rule.right[index], layers)]).val;
				loops += 1;
				
				if (index == 0 && layers == level.layers){
					break;
				} else if (loops > MAX_LOOPS) {
					break;
				}
			}
		}
		
		layers = rotate_level(layers);
	}
	
	level.layers = layers;
	if (!changed) return <engine, level>;
	
	for (Command cmd <- rule.commands){
		if (engine.abort) return <engine, level>;
		engine = run_command(cmd, engine);
	}
		
	return <engine, level>;
}

tuple[Engine, Level] rewrite(Engine engine, Level level, bool late){
	list[Rule] rules = [x | Rule x <- engine.rules, x.late == late];

	for (Rule rule <- rules){
		if (engine.abort) break;
		<engine, level> = apply_rule(engine, level, rule);
	}
	
	return <engine, level>;
}

list[str] MOVES = ["left", "up", "right", "down"];
tuple[Engine, Level] do_turn(Engine engine, Level level : level(_, _, _, _, _, _), str input){
	if (input == "undo"){
		return <engine, undo(level)>;
	} else if (input == "restart"){
		return <engine, restart(level)>;
	}
	
	// pre-run before the move
	do {
		engine.again = false;
		<engine, level> = rewrite(engine, level, false);
	} while (engine.again && !engine.abort);
	
	if (input in MOVES){
		level = plan_move(level, input);
	}
	
	// run during the move
	do {
		engine.again = false;
		<engine, level> = rewrite(engine, level, false);
	} while (engine.again && !engine.abort);
	
	level = do_move(level);
	
	// post-run after the move
	do {
		engine.again = false;
		<engine, level> = rewrite(engine, level, true);
	} while (engine.again && !engine.abort);
	
	level.objectdata = update_objectdata(level);
	return <engine, level>;
}

tuple[Engine, Level] do_turn(Engine engine, Level level : message(_, _)){
	return <engine, level>;
}

// temporary substitute to getting user input
tuple[str, int] get_input(list[str] moves, int index){
	str move = moves[index];
	index += 1;
	return <move, index>;
}

Coords shift_coords(Layer lyr, Coords coords, str direction : "left"){
	if (coords.y - 1 < 0) return coords;
	
	return <coords.x, coords.y - 1, coords.z>;
}

Coords shift_coords(Layer lyr, Coords coords, str direction : "right"){
	if (coords.y + 1 >= size(lyr[coords.x])) return coords;
	
	return <coords.x, coords.y + 1, coords.z>;
}

Coords shift_coords(Layer lyr, Coords coords, str direction : "up"){
	if (coords.x - 1 < 0) return coords;
	
	return <coords.x - 1, coords.y, coords.z>;
}

Coords shift_coords(Layer lyr, Coords coords, str direction : "down"){
	if (coords.x + 1 >= size(lyr)) return coords;
	
	return <coords.x + 1, coords.y, coords.z>;
}

default Coords shift_coords(_, _, str dir) { 
	throw "expected valid direction, got <dir>"; 
}

Level move_obstacle(Level level, Coords coords, Coords other_neighbor_coords){
	Object obj = level.layers[coords.z][coords.x][coords.y];
	if (!(obj is moving_object)) return level;
	
	Coords neighbor_coords = shift_coords(level.layers[coords.z], coords, obj.direction);
	if (coords == neighbor_coords) return level;
	
	Object neighbor_obj = level.layers[neighbor_coords.z][neighbor_coords.x][neighbor_coords.y];
	if (!(neighbor_obj is transparent) && neighbor_coords != other_neighbor_coords) level = move_obstacle(level, neighbor_coords, coords);
	
	neighbor_obj = level.layers[neighbor_coords.z][neighbor_coords.x][neighbor_coords.y];
	if (neighbor_obj is transparent) {
		level.layers[coords.z][coords.x][coords.y] = new_transparent(coords);
		level.layers[coords.z][neighbor_coords.x][neighbor_coords.y] = object(obj.name, obj.id, neighbor_coords);
	}
	
	return level;
}

Level do_move(Level level){
	for (int i <- [0..size(level.layers)]){
		Layer layer = level.layers[i];
		for(int j <- [0..size(layer)]){
			Line line = layer[j];
			for(int k <- [0..size(line)]){
				level = move_obstacle(level, <j, k, i>, <j, k, i>); 
			}
		}
	}
	
	if (level.states[-1] != level.layers) level.states += [deep_copy(level.layers)];
	return level;
}

list[bool] is_on(Level level, list[str] objs, list[str] on){
	list[bool] results = [];	
	for (int i <- [0..size(level.layers)]){
		Layer layer = level.layers[i];
		for(int j <- [0..size(layer)]){
			Line line = layer[j];
			for(int k <- [0..size(line)]){
				Object obj = line[k];
				if (obj.name in objs){
					bool t = false;
					for (int l <- [0..size(level.layers)]){
						if (level.layers[l][j][k].name in on) t = true;
					}
					
					results += [t];
				}
			}
		}
	} 


	return results;
}

bool is_victorious(Engine engine, Level level){
	if (engine.win_keyword || level is message) return true;
	
	victory = true;
	for (Condition cond <- engine.conditions){
		switch(cond){
			case no_objects(list[str] objs): {
				// if any objects present then we don't win
				if (any(str x <- objs, x in level.objectdata)) victory = false;
			}
			
			case some_objects(list[str] objs): {
				// if not any objects present then we dont' win
				if (!any(str x <- objs, x in level.objectdata)) victory = false;
			}
			
			case no_objects_on(list[str] objs, list[str] on): {
				// if any objects are on any of the ons then we don't win
				list[bool] results = is_on(level, objs, on);
				if (any(x <- results, x)) victory = false;
			}
			
			case some_objects_on(list[str] objs, list[str] on): {
				// if no objects are on any of the ons then we don't win
				list[bool] results = is_on(level, objs, on);
				if (!isEmpty(results) && !any(x <- results, x)) victory = false;
			}
			
			case all_objects_on(list[str] objs, list[str] on): {
				// if not all objects are on any of the ons then we don't win
				list[bool] results = is_on(level, objs, on);
				if (!isEmpty(results) && !all(x <- results, x)) victory = false;
			}
		}
	}

	return victory;
}

Engine run_command(Command cmd : again(), Engine engine){
	engine.again = true;
	return engine;
}

Engine run_command(Command cmd : checkpoint(), Engine engine){
	engine.current_level = checkpoint(level);
	return engine;
}

Engine run_command(Command cmd : cancel(), Engine engine){
	engine.abort = true;
	engine.current_level = undo(engine.current_level);
	return engine;
}

Engine run_command(Command cmd : win(), Engine engine){
	engine.abort = true;
	engine.win_keyword = true;
	return engine;
}

Engine run_command(Command cmd : restart(), Engine engine){
	engine.abort = true;
	engine.current_level = restart(engine.current_level);
	return engine;
}

Engine run_command(Command cmd : message(str string), Engine engine){
	engine.msg_queue += [string];
	return engine;
}

Engine run_command(Command cmd : sound(str event), Engine engine){
	engine.sound_queue += [event];
	return engine;
}

void print_level(Level l: message(str msg, _)){
	print_message(msg);
}

void print_level(Level l : level){

	str pixel(str p : "trans") = ".";
	default str pixel(str p) = p[0];
	
	//for (Layer lyr <- l.layers){
	//	for (Line line <- lyr) {
	//		print(intercalate("", [pixel(x.name) | x <- line]));
	//		//print("   ");
	//		//print(intercalate(" ", line));
	//		println();
	//	}
	//	println();
	//}
	
	for (Line line <- l.layers[-1]) {
		print(intercalate("", [pixel(x.name) | x <- line]));
		//print("   ");
		//print(intercalate(" ", line));
		println();
	}
	println();
}

list[Layer] deep_copy(list[Layer] lyrs){
	list[Layer] layers = [];
	for (Layer lyr <- lyrs){
		list[Line] layer = [];
		for (Line lin <- lyr){
			layer += [[x | Object x <- lin]];
		}
		
		layers += [layer];
	}
	
	return layers;
}

Level plan_move(Level level, str direction){	
	for (int i <- [0..size(level.layers)]){
		Layer layer = level.layers[i];
		for(int j <- [0..size(layer)]){
			Line line = layer[j];
			for(int k <- [0..size(line)]){
				Object obj = line[k];
				if (line[k].name == "player"){
					level.layers[i][j][k] = moving_object(obj.name, obj.id, direction, <j, k, i>);
				}
			}
		}
	}
	
	return level;
}

void play_sound(Engine engine, str event){
	if (event in engine.sounds) {
		println(engine.sounds[event]);
	}
}

void print_message(str string){
	println("#####################################################");
	println(string);
	println("#####################################################");
}

void game_loop(Checker c, list[str] moves){
	Engine engine = compile(c);
	
	print_level(engine.current_level);
	int index = 0;
	str input;
	while (true){
		<input, index> = get_input(moves, index);
		<engine, engine.current_level> = do_turn(engine, engine.current_level, input);
		
		for (str event <- engine.sound_queue){
			play_sound(engine, event);
		}
		
		for (str msg <- engine.msg_queue){
			print_message(msg);
		}
		
		print_level(engine.current_level);
		
		bool victory = is_victorious(engine, engine.current_level);
		if (victory && is_last(engine)){
			break;
		} else if (victory) {
			engine = change_level(engine, engine.index + 1);
		}
		
		engine.abort = false;
	}
	
	println("VICTORY");
}
