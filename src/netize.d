import std.traits;
import std.conv;
import std.algorithm;
import std.range;
import xserial;

enum Read	;
enum Write	;
enum SplitArray	;
struct Sync {
	ubyte	valueId	;
}
enum Changer	;
enum Change	;

template Owner(bool isOwner) {
	static if (isOwner)
		mixin("alias Owner = Write;");
	else 
		mixin("alias Owner = Read;");
}
////mixin template Owner(string name, bool isOwner) {
////	static if (isOwner) {
////		mixin("alias "name~"=Read");
////	else 
////		mixin("alias "name~"=Read");
////}

alias _Ntz = __Ntz!();
template __Ntz() {
	/**
	 * Copied and slightly modified from Phobos `std.traits`. (dlang.org/phobos/std_traits.html)
	 */
	private template isDesiredUDA(alias attribute, alias toCheck)
	{
		/*added*/ import std.traits;
		static if (is(typeof(attribute)) && !__traits(isTemplate, attribute))
		{
			static if (__traits(compiles, toCheck == attribute))
				enum isDesiredUDA = toCheck == attribute;
			else
				enum isDesiredUDA = false;
		}
		else static if (is(typeof(toCheck)))
		{
			static if (__traits(isTemplate, attribute))
				enum isDesiredUDA =  isInstanceOf!(attribute, typeof(toCheck));
			else
				enum isDesiredUDA = is(typeof(toCheck) == attribute);
		}
		else static if (__traits(isTemplate, attribute))
			enum isDesiredUDA = isInstanceOf!(attribute, toCheck);
		else
			enum isDesiredUDA = is(toCheck == attribute);
	}
	
	ubyte[] getIds(T)() {
		import std.experimental.logger;
		import std.traits;
		import std.algorithm;
		ubyte[] ids;
		static foreach(var; getSymbolsByUDA!(T, Sync)) {
			ids ~= getUDAs!(var, Sync)[0].valueId;
		}
		ids = ids	.sort	
			.uniq	
			.array	;
		return ids;
	}
	
	mixin template VarParts(T,ubyte varId) {
		
	}
	
	string getMixin(T)() {
		enum ids = getIds!T;
		bool[ubyte] hasWrite;
		bool[ubyte] hasRead;
		string getUpdateMixin() {
			string toMix = "";
			foreach(id; ids) {
				string idString = to!string(id);
				if (hasWrite[id]) {
					toMix ~= "
						newMsgs(netizeUpdateSync!"~idString~");
					";
				}
			}
			return toMix;
		}
		string getUpdateMsgMixin() {
			string toMix = "";
			foreach(id;ids) {
				string idString = to!string(id);
				if (hasRead[id]) {
					toMix ~= "
						if (msg[0]=="~idString~") {
							import xserial;
							try {
								_Ntz.deserialize!("~idString~")(this, msg[1..$]);
							}
							catch(BufferOverflowException e) {
								error(\"Bad Msg: BufferOverflowException\");
							}
						}
					";
				}
			}
			return toMix;
		}
		string toMix = "";
		static foreach(id; ids) {{
			enum idString = to!string(id);
			alias vars = getSymbolsByUDA!(T,Sync(id));
			static assert(vars.length>0);
			static if (vars.length==1 && hasUDA!(vars[0],SplitArray)) {
			}
			else {
				static foreach (i; 0..vars.length) {{
					static assert(__traits(identifier,vars[i])[0]=='_');
					enum name = __traits(identifier,vars[i])[1..$];
					static assert(!hasUDA!(mixin("T._"~name),SplitArray));
					// getter
					toMix ~= "
						@property auto "~name~"() {
							return cast(const)_"~name~";
						}
					";
					static if (hasUDA!(vars[i],Write) || !hasUDA!(vars[i],Read)) { // has write (or neither causes default read and write)
						hasWrite[id] = true;
						// setter
						toMix ~= "
							@property void "~name~"(typeof(_"~name~") n) {
								_"~idString~"_changed = true;
								_"~name~" = n;
							}
						";
						static if(hasUDA!(vars[i],Changer)) {
							toMix ~= "
								@property ref auto "~name~"_changer() {
									_"~idString~"_changed = true;
									return _"~name~";
								}
							";
						}
						static if(hasUDA!(vars[i],Change)) {
							toMix ~= "
								void "~name~"_change() {
									_"~idString~"_changed = true;
								}
							";
						}
					}
					static if (hasUDA!(vars[i],Read) || !hasUDA!(vars[i],Write)) { // has read (or neither causes default read and write)
						hasRead[id] = true;
					}
				}}
				if (!(id in hasWrite))
					hasWrite[id] = false;
				if (!(id in hasRead))
					hasRead[id] = false;
					
				if (hasWrite[id]) {
					toMix ~= "bool _"~idString~"_changed = false;";
					// updater
					toMix ~= "
						ubyte[][] netizeUpdateSync(ubyte id:"~idString~")() {
							ubyte[][] msgs = [];
							if (_"~idString~"_changed) {
								import xserial;
								msgs ~= ["~idString~"~_Ntz.serizalize!("~idString~")(this)];
								_"~idString~"_changed = false;
							}
							return msgs;
						}
					";
				}
			}
		}}
		toMix~="
			ubyte[][] netizeUpdate(ubyte[][] inMsgs, void delegate(string) error_callback=null) {
				void error(string msg) {
					if (error_callback is null)
						_Ntz.defaultError	(msg);
					else	error_callback	(msg);
				}
				enum ids = ["~ids.map!(to!string).map!"a~','".fold!"a~b"~"];
				foreach(msg;inMsgs) {
					try {
						if (msg.length==0) {
							error(\"Bad Msg: msg without anything in it\");
						}
						else if (ids.countUntil(msg[0])==-1) {
							error(\"Bad Msg: invalid id\");
						}
						else {
							"~getUpdateMsgMixin~"
						}
					}
					catch(Throwable e) {
						error(\"Bad Msg: something went wrong in decoding error\");
					}
				}
				ubyte[][] msgs = [];
				void newMsg(ubyte[] m) {msgs~=m;}
				void newMsgs(ubyte[][] m) {msgs~=m;}
				"~getUpdateMixin~"
				return msgs;
			}
		";
		return toMix;
	}
	
	ubyte[] serizalize(ubyte id,T)(T cls) {
		return Serializer!(Exclude,Includer!(Sync(id)),Endian.littleEndian,Length!ubyte).serialize(cls);
	}
	T deserialize(ubyte id,T)(T cls, ubyte[] msg) {
		return Serializer!(Exclude,Includer!(Sync(id)),Endian.littleEndian,Length!ubyte).deserialize(cls, msg);
	}
	void defaultError(string msg) {
		import std.stdio;
		"Error in Netize: ".writeln(msg);
	}
}


mixin template Netize() {
	mixin(_Ntz.getMixin!(typeof(this)));
}

// Basic
unittest {
	class TestA {
		@Sync(0) int _a;
		mixin Netize;
	}
	class TestB {
		@Sync(0) int _a;
		@Sync(1) int[] _b;
		mixin Netize;
	}
	class TestC {
		@Sync(0) int _a;
		@Sync(0) int[] _b;
		mixin Netize;
	}
	class TestD {
		@Sync(0) int _a;
		@Sync(0) int[] _b;
		@Sync(1) int _c;
		mixin Netize;
	}
	// Changed (this test could probably be remove, this test is not essential just suggests an error that could be hard to track)
	{
		{
			TestA test = new TestA;
			assert(!test._0_changed);
			test.a = 5;
			assert(test.a==5);
			assert(test._0_changed);
			test.netizeUpdate([],(a){});
			assert(!test._0_changed);
			assert(test.a==5);
		}
		{
			TestB test = new TestB;
			assert(!test._0_changed && !test._1_changed);
			test.a = 5;
			assert(test.a==5);
			assert(test._0_changed && !test._1_changed);
			test.netizeUpdate([],(_){});
			assert(!test._0_changed && !test._1_changed);
			assert(test.a==5);
			
			test.b = [1,2];
			assert(test.b==[1,2]);
			assert(!test._0_changed && test._1_changed);
			test.netizeUpdate([],(_){});
			assert(!test._0_changed && !test._1_changed);
			assert(test.b==[1,2]);
			assert(test.a==5);
			
			test.a = 8;
			test.b = [3,5];
			assert(test.a==8);
			assert(test.b==[3,5]);
			assert(test._0_changed && test._1_changed);
			test.netizeUpdate([],(_){});
			assert(!test._0_changed && !test._1_changed);
			assert(test.a==8);
			assert(test.b==[3,5]);
		}
		{
			TestC test = new TestC;
			assert(!test._0_changed);
			test.a = 5;
			assert(test.a==5);
			assert(test._0_changed);
			test.netizeUpdate([],(_){});
			assert(!test._0_changed);
			assert(test.a==5);
			
			test.b = [1,2];
			assert(test.b==[1,2]);
			assert(test._0_changed);
			test.netizeUpdate([],(_){});
			assert(!test._0_changed);
			assert(test.b==[1,2]);
			assert(test.a==5);
			
			test.a = 8;
			test.b = [3,5];
			assert(test.a==8);
			assert(test.b==[3,5]);
			assert(test._0_changed);
			test.netizeUpdate([],(_){});
			assert(!test._0_changed);
			assert(test.a==8);
			assert(test.b==[3,5]);
		}
		{
			TestD test = new TestD;
			test.a = 1;
			test.b = [2,3,4];
			test.c = 5;
			assert(test.a==1);
			assert(test.b==[2,3,4]);
			assert(test.c==5);
			assert(test._0_changed && test._1_changed);
			test.netizeUpdate([],(_){});
			assert(!test._0_changed && !test._1_changed);
			assert(test.a==1);
			assert(test.b==[2,3,4]);
			assert(test.c==5);
		}
	}
	// Serialize and Deserialze
	{
		TestA testa = new TestA;
		TestA testb = new TestA;
		testa.a = 2;
		auto msgs = testa.netizeUpdate([],(a){assert(0);});
		assert(testb.netizeUpdate(msgs).length==0);
		assert(testb.a == 2);
	}
	// Bad msg data
	{
		{
			TestA test = new TestA;
			// nonexistent `Sync`
			{
				bool failed = false;
				test.netizeUpdate([[100]],(msg){failed=true;});
				assert(failed);
			}
			// no data for 0
			{
				bool failed = false;
				test.netizeUpdate([[0]],(msg){failed=true;});
				assert(failed);
			}
			// no data at all
			{
				bool failed = false;
				test.netizeUpdate([[]],(msg){failed=true;});
				assert(failed);
			}
			// no enough data
			{
				bool failed = false;
				test.netizeUpdate([[0,1,2,5]],(msg){failed=true;});
				assert(failed);
			}
		}
		{
			TestC test = new TestC;
			// no enough data; array length to long
			{
				bool failed = false;
				test.netizeUpdate([[0,1,0,0,0,2,2,5,1,2]],(msg){failed=true;});
				assert(failed);
			}
			// no enough data in of array value
			{
				bool failed = false;
				test.netizeUpdate([[0,1,0,0,0,1,2,5]],(msg){failed=true;});
				assert(failed);
			}
			// not implemented
			////// msg fully ignored on invalid
			////{
			////	bool failed = false;
			////	test.netizeUpdate([[0,1,0,0,0,0]],(msg){assert(0);});
			////	assert(test.a==1);//double check set right
			////	test.netizeUpdate([[0,5,5,0,0,1,2,5]],(msg){failed=true;});
			////	assert(failed);
			////	assert(test.a==1);
			////}
			////// msg to long
			////{
			////	bool failed = false;
			////	test.netizeUpdate([[0,5,5,0,0,1,2,5,5,4,4,4,3,1,2,2,3]],(msg){failed=true;});
			////	assert(failed);
			////}
		}
	}
}			
// Read and Write
unittest {
	class TestAA {
		@Sync(0) @Read int _a;
		@Sync(1) @Write int _b;
		mixin Netize;
	}
	class TestAB {
		@Sync(0) @Write int _a;
		@Sync(1) @Read int _b;
		mixin Netize;
	}
	class TestB(bool who) {
		@Sync(0) @Owner!(!who) int _a;
		@Sync(1) @Owner!(who) int _b;
		mixin Netize;
	}
	{
		static foreach(i;0..2) {{
			static if(i==0) {
				auto testa = new TestAA;
				auto testb = new TestAB;
			}
			else static if(i==1){
				auto testa = new TestB!true;
				auto testb = new TestB!false;
			}
			if (__traits(compiles, testa.a=5))
				assert(0);
			if (!__traits(compiles, testb.a=5))
				assert(0);
			if (!__traits(compiles, testa.b=5))
				assert(0);
			if (__traits(compiles, testb.b=5))
				assert(0);
			
			assert(testa.a==0&&testb.a==0&&testa.b==0&&testb.b==0);
			testa.b = 2;
			assert(testa.a==0&&testb.a==0&&testa.b==2&&testb.b==0);
			auto msgs = testa.netizeUpdate([],(a){assert(0);});
			assert(testb.netizeUpdate(msgs).length==0);
			assert(testa.a==0&&testb.a==0&&testa.b==2&&testb.b==2);
			testb.a = 4;
			assert(testa.a==0&&testb.a==4&&testa.b==2&&testb.b==2);
			msgs = testb.netizeUpdate([],(a){assert(0);});
			assert(testa.netizeUpdate(msgs).length==0);
			assert(testa.a==4&&testb.a==4&&testa.b==2&&testb.b==2);
		}}
	}
}
// Change and Changer
unittest {
	class TestA {
		@Change @Sync(0) int _a;
		mixin Netize;
	}
	class TestB {
		@Changer @Sync(0) int _a;
		mixin Netize;
	}
	class TestC {
		@Change @Changer @Sync(0) int _a;
		mixin Netize;
	}
	{
		auto testa = new TestA;
		auto testb = new TestB;
		auto testc = new TestC;
		
		assert(!testa._0_changed);
		testa.a_change;
		assert(testa._0_changed);
		testa.netizeUpdate([],(a){assert(0);});
		assert(!testa._0_changed);
		
		assert(!testc._0_changed);
		testc.a_change;
		assert(testc._0_changed);
		testc.netizeUpdate([],(a){assert(0);});
		assert(!testc._0_changed);
		
		
		assert(!testb._0_changed);
		testb.a_changer = 1;
		assert(testb._0_changed);
		assert(testb.netizeUpdate([],(a){assert(0);})==[[0,1,0,0,0]]);
		assert(!testb._0_changed);
		
		assert(!testc._0_changed);
		testc.a_changer = 2;
		assert(testc._0_changed);
		assert(testc.netizeUpdate([],(a){assert(0);})==[[0,2,0,0,0]]);
		assert(!testc._0_changed);
	}
	class TestD {
		@Changer @Change @Sync(0) int[] _a;
		mixin Netize;
	}
	{
		auto testa = new TestD;
		
		assert(!__traits(compiles,testa.a~=1));
		
		assert(!testa._0_changed);
		testa.a_changer ~= 1;
		assert(testa._0_changed);
		assert(testa.netizeUpdate([],(a){assert(0);})==[[0,1,1,0,0,0]]);
		assert(!testa._0_changed);
		
		assert(!__traits(compiles,mixin("testa.a[0]=1")));
		
		testa.a_changer[0] = 2;
		assert(testa._0_changed);
		assert(testa.netizeUpdate([],(a){assert(0);})==[[0,1,2,0,0,0]]);
		assert(!testa._0_changed);
		
		
		int[] a = [1,2];
		
		testa.a = a;
		assert(testa._0_changed);
		assert(testa.netizeUpdate([],(a){assert(0);})==[[0,2,1,0,0,0,2,0,0,0]]);
		assert(!testa._0_changed);
		
		a[1] = 4;
		assert(!testa._0_changed);
		testa.a_change;
		assert(testa._0_changed);
		assert(testa.netizeUpdate([],(a){assert(0);})==[[0,2,1,0,0,0,4,0,0,0]]);
		assert(!testa._0_changed);
	}
}
////// Array with objects
////unittest {
////	class Sub {
////		@Sync(0) int a;
////	}
////	class TestA {
////		@Sync(0) Sub[]
////	}
////}

////mixin template NetworkVar() {
////	////mixin(_NV.getMixin!(typeof(this)));
////	private import std.traits;
////	private import std.algorithm : countUntil;
////	private import std.conv : to;
////	enum _networkVar_private_varName	= q{__traits(identifier, var)[1..$]};
////	enum _networkVar_private_varId	= q{getUDAs!(var, Sync)[0].valueId};
////	enum _networkVar_private_varIdStr	= _networkVar_private_varId~".to!string";
////	static foreach(var; getSymbolsByUDA!(typeof(this), Sync)) {
////		static assert(__traits(identifier, var)[0]=='_');
////		@property mixin("auto "~mixin(_networkVar_private_varName)~"() {
////			return _"~mixin(_networkVar_private_varName)~";
////		}");
//// 		static if (hasUDA!(var,Write)) {
////			static if (hasUDA!(var,SplitArray)) {
////				mixin("size_t _networkVar_"~mixin(_networkVar_private_varIdStr)~"_added = 0;");
////				mixin("size_t[] _networkVar_"~mixin(_networkVar_private_varIdStr)~"_removed = [];");
////				@property mixin("void "~mixin(_networkVar_private_varName)~"_add(typeof(*var.ptr) n) {
////					_"~mixin(_networkVar_private_varName)~"	~= n	;
////					_networkVar_"~mixin(_networkVar_private_varIdStr)~"_added	+= 1	;
////				}");
////				@property mixin("void "~mixin(_networkVar_private_varName)~"_remove(typeof(*var.ptr) n) {
////					size_t i = _"~mixin(_networkVar_private_varName)~".countUntil(n);
////					_"~mixin(_networkVar_private_varName)~" = _"~mixin(_networkVar_private_varName)~".remove(i);
////					_networkVar_"~mixin(_networkVar_private_varIdStr)~"_removed	~= i;
////				}");
////			}
////			else {
////				static if (!is(typeof(mixin("_networkVar_"~mixin(_networkVar_private_varIdStr)~"_changed")))) {
////					mixin("bool _networkVar_"~mixin(_networkVar_private_varIdStr)~"_changed = false;");
////				}
////				@property mixin("void "~mixin(_networkVar_private_varName)~"(typeof(var) n) {
////					if ("~mixin(_networkVar_private_varName)~"!=n) {
////						_"~mixin(_networkVar_private_varName)~"	= n	;
////						_networkVar_"~mixin(_networkVar_private_varIdStr)~"_changed	= true	;
////					}
////				}");
////			}	
////		}
////	}
////	void networkVar_update(void delegate(ubyte[]) msg_callback, ubyte[][] msgs) {
////		_networkVar_private_update(this, msg_callback, msgs);
////	}
////	static void _networkVar_private_update(typeof(this) this_, void delegate(ubyte[]) msg_callback, ubyte[][] msgs) {
////		enum Event : ubyte {
////			add	,
////			remove	,
////			update	,
////		}
////		pragma(inline, true) ubyte[] serialize(uint valueId)() {
////			return [9,9,9,9];
////		}
////		pragma(inline, true) void deserialize(ubyte[] msg) {
////			msg.log;
////		}
////		
////		foreach (msg; msgs) {
////			deserialize(msg);
////		}
////		static foreach(var; getSymbolsByUDA!(typeof(this), Sync)) {
////			static if (hasUDA!(var,Write)) {
////				static if (hasUDA!(var,SplitArray)) {
////					foreach (added; 0..mixin("this_._networkVar_"~mixin(_networkVar_private_varIdStr)~"_added")) {
////						msg_callback([mixin(_networkVar_private_varId), Event.add]);
////					}
////					mixin("this_._networkVar_"~mixin(_networkVar_private_varIdStr)~"_added") = 0;
////					foreach (removed; mixin("this_._networkVar_"~mixin(_networkVar_private_varIdStr)~"_removed")) {
////						msg_callback([mixin(_networkVar_private_varId), Event.remove, (cast(ubyte)removed)]);
////					}
////					mixin("this_._networkVar_"~mixin(_networkVar_private_varIdStr)~"_removed") = [];
////					
////					foreach (i, entity; mixin("this_._"~mixin(_networkVar_private_varName))) {
////						entity.networkVar_update((msg){
////							ubyte[] header = [mixin(_networkVar_private_varId), Event.update,(cast(ubyte)i)];
////							msg_callback(header~msg);
////						},[]);
////					}
////				}
////				else {
////					if (mixin("this_._networkVar_"~mixin(_networkVar_private_varIdStr)~"_changed")) {
////						msg_callback([mixin(_networkVar_private_varId)]~serialize!(mixin(_networkVar_private_varId)));
////						mixin("this_._networkVar_"~mixin(_networkVar_private_varIdStr)~"_changed") = false;
////					}
////				}
////			}
////		}
////	}
////}



