/**
 * This file is part of DCD, a development tool for the D programming language.
 * Copyright (C) 2014 Brian Schott
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

module dsymbol.conversion.first;

import containers.unrolledlist;
import dparse.ast;
import dparse.formatter;
import dparse.lexer;
import dsymbol.builtin.names;
import dsymbol.builtin.symbols;
import dsymbol.cache_entry;
import dsymbol.import_;
import dsymbol.modulecache;
import dsymbol.scope_;
import dsymbol.semantic;
import dsymbol.string_interning;
import dsymbol.symbol;
import dsymbol.type_lookup;
import std.algorithm.iteration : map;
import std.array : appender;
import std.experimental.allocator;
import std.experimental.allocator.gc_allocator : GCAllocator;
import std.experimental.logger;
import std.meta : AliasSeq;
import std.typecons : Rebindable;
import stdio = std.stdio;



package void writeln(F, A...)(F f, A args)
{
	//debug stdio.writeln(f, args);
}



/**
 * First Pass handles the following:
 * $(UL
 *     $(LI symbol name)
 *     $(LI symbol location)
 *     $(LI alias this locations)
 *     $(LI base class names)
 *     $(LI protection level)
 *     $(LI symbol kind)
 *     $(LI function call tip)
 *     $(LI symbol file path)
 * )
 */
final class FirstPass : ASTVisitor
{
	/**
	 * Params:
	 *     mod = the module to visit
	 *     symbolFile = path to the file being converted
	 */
	this(const Module mod, istring symbolFile,
		ModuleCache* cache, CacheEntry* entry = null)
	in
	{
		assert(mod);
		assert(cache);
	}
	do
	{
		this.mod = mod;
		this.symbolFile = symbolFile;
		this.entry = entry;
		this.cache = cache;
	}

	/**
	 * Runs the against the AST and produces symbols.
	 */
	void run()
	{
		visit(mod);

		writeln("-");
		writeln("-------- end first pass");
		writeln("-");
	}

	override void visit(const Unittest u)
	{
		// Create a dummy symbol because we don't want unit test symbols leaking
		// into the symbol they're declared in.
		pushSymbol(UNITTEST_SYMBOL_NAME,
			CompletionKind.dummy, istring(null));
		scope(exit) popSymbol();
		u.accept(this);
	}

	override void visit(const Constructor con)
	{
		visitConstructor(con.location, con.parameters, con.templateParameters, con.functionBody, con.comment);
	}

	override void visit(const SharedStaticConstructor con)
	{
		visitConstructor(con.location, null, null, con.functionBody, con.comment);
	}

	override void visit(const StaticConstructor con)
	{
		visitConstructor(con.location, null, null, con.functionBody, con.comment);
	}

	override void visit(const Destructor des)
	{
		visitDestructor(des.index, des.functionBody, des.comment);
	}

	override void visit(const SharedStaticDestructor des)
	{
		visitDestructor(des.location, des.functionBody, des.comment);
	}

	override void visit(const StaticDestructor des)
	{
		visitDestructor(des.location, des.functionBody, des.comment);
	}


	//override void visit(const FunctionCallExpression fce)
	//{
	//	assert(fce);



	//	auto fnToken = fce.tokens[0];
	//    warning("--------------------FunctionCallExpression> ", fnToken);

	//	//pushSymbol(fnToken.text, CompletionKind.functionName, symbolFile, fnToken.index);
	//	//scope (exit) popSymbol();
	//	//currentSymbol.acSymbol.qualifier = SymbolQualifier.func;

	//	//warning("-- ", fnToken.text);

	//	//if (fce.arguments && fce.arguments.namedArgumentList)
	//	//{
	//	//	processFunctionArgs(fce.arguments);
	//	//}
	//}

	void processFunctionArgs(const Arguments args)
	{
		auto argsList = args.namedArgumentList;

		pushScope(argsList.startLocation, argsList.endLocation);
		scope (exit) popScope();

		currentSymbol.acSymbol.functionParameters.reserve(argsList.items.length);
		foreach(arg; argsList.items)
		{
			auto argToken = arg.tokens[0];
			bool named = arg.tokens.length >= 3 && arg.tokens[1] == tok!(":");

			// TODO: suport token chain,  myfunc(SomeType.variable);

			auto firstTokenIndex = named ? 2 : 0;
			auto tokens = arg.tokens[firstTokenIndex .. $];
			auto firstToken = tokens[0];

			writeln(" arg: ", firstToken.text, " pos: ", firstToken.index, " named: ", named, " l: ", arg.tokens.length);

			SemanticSymbol* parameter = allocateSemanticSymbol(
				firstToken.text, CompletionKind.variableName, symbolFile,
				firstToken.index);

			parameter.parent = currentSymbol;

			currentSymbol.acSymbol.functionParameters ~= parameter.acSymbol;

			currentSymbol.addChild(parameter, true);
			currentScope.addSymbol(parameter.acSymbol, false);
		}
	}

	override void visit(const FunctionDeclaration dec)
	{
		//writeln("    FunctionDeclaration: "   , dec.name.text);
		//string currentVersion = versionBuffer.back();
		//if (versionRelevantToOS(currentVersion) == false) return;
		assert(dec);
		pushSymbol(dec.name.text, CompletionKind.functionName, symbolFile,
				dec.name.index, dec.returnType);
		scope (exit) popSymbol();
		currentSymbol.acSymbol.protection = protection.current;
		currentSymbol.acSymbol.doc = makeDocumentation(dec.comment);
		currentSymbol.acSymbol.qualifier = SymbolQualifier.func;
		istring lastComment = this.lastComment;
		this.lastComment = istring.init;
		scope(exit) this.lastComment = lastComment;

		if (dec.functionBody !is null)
		{
			size_t start = dec.name.index + dec.name.text.length;
			size_t end = dec.functionBody.endLocation;
			currentSymbol.acSymbol.location = start;
			currentSymbol.acSymbol.location_end = end;

			pushFunctionScope(dec.functionBody, start);
			scope (exit) popScope();
			processParameters(currentSymbol, dec.returnType,
					currentSymbol.acSymbol.name, dec.parameters, dec.templateParameters);
			dec.functionBody.accept(this);
		}
		else
		{
			processParameters(currentSymbol, dec.returnType,
					currentSymbol.acSymbol.name, dec.parameters, dec.templateParameters);
		}

		if (dec.returnType !is null){
			addTypeWithContext(currentSymbol, dec.returnType);
		}
		else if (dec.functionBody !is null)
		{
			// A function with no declared return type is `auto`: the only
			// place its type appears is its `return` expression, recorded
			// while the body was walked above.  Handling it here rather than
			// in a separate walk keeps the cost to one assignment per
			// `return` statement.
			if (currentSymbol.autoReturnExpression !is null)
				populateInitializer(currentSymbol, currentSymbol.autoReturnExpression);
			else if (dec.functionBody.shortenedFunctionBody !is null
				&& dec.functionBody.shortenedFunctionBody.expression !is null)
				populateInitializer(currentSymbol,
					dec.functionBody.shortenedFunctionBody.expression);
		}
	}

	override void visit(const FunctionLiteralExpression exp)
	{
		assert(exp);

		auto fbody = exp.specifiedFunctionBody;
		if (fbody is null)
			return;
		auto block = fbody.blockStatement;
		if (block is null)
			return;

		pushSymbol(FUNCTION_LITERAL_SYMBOL_NAME, CompletionKind.dummy, symbolFile,
			block.startLocation, null);
		scope(exit) popSymbol();

		pushScope(block.startLocation, block.endLocation);
		scope (exit) popScope();
		processParameters(currentSymbol, exp.returnType,
				FUNCTION_LITERAL_SYMBOL_NAME, exp.parameters, null);
		block.accept(this);
	}

	override void visit(const ClassDeclaration dec)
	{
		visitAggregateDeclaration(dec, CompletionKind.className);
	}

	override void visit(const TemplateDeclaration dec)
	{
		visitAggregateDeclaration(dec, CompletionKind.templateName);
	}

	override void visit(const InterfaceDeclaration dec)
	{
		visitAggregateDeclaration(dec, CompletionKind.interfaceName);
	}

	override void visit(const UnionDeclaration dec)
	{
		visitAggregateDeclaration(dec, CompletionKind.unionName);
	}

	override void visit(const StructDeclaration dec)
	{
		visitAggregateDeclaration(dec, CompletionKind.structName);
	}

	override void visit(const NewAnonClassExpression nace)
	{
		// its base classes would be added as inherit lookups in the current symbol
		skipBaseClassesOfNewAnon = true;
		nace.accept(this);
		skipBaseClassesOfNewAnon = false;
	}

	override void visit(const BaseClass bc)
	{
		if (skipBaseClassesOfNewAnon)
			return;
		if (bc.type2.typeIdentifierPart is null ||
			bc.type2.typeIdentifierPart.identifierOrTemplateInstance is null)
			return;
		auto lookup = TypeLookupsAllocator.instance.make!TypeLookup(TypeLookupKind.inherit);
		lookup.astNode = bc;
		currentSymbol.typeLookups.insert(lookup);

		// create an alias to the BaseClass to allow completions
		// of the form : `instance.BaseClass.`, which is
		// mostly used to bypass the most derived overrides.
		const idt = lastTypeIdentifierName(bc.type2.typeIdentifierPart);
		if (!idt.length)
			return;
		SemanticSymbol* symbol = allocateSemanticSymbol(idt,
			CompletionKind.aliasName, symbolFile, currentScope.endLocation);
		Type t = TypeLookupsAllocator.instance.make!Type;
		t.type2 = cast() bc.type2;
		addTypeToLookups(symbol.typeLookups, t);
		symbol.parent = currentSymbol;
		currentSymbol.addChild(symbol, true);
		symbol.acSymbol.protection = protection.current;
	}



	override void visit(const VariableDeclaration dec)
	{
		assert (currentSymbol);

		foreach (declarator; dec.declarators)
		{
			CompletionKind kind = CompletionKind.variableName;
			if (currentSymbol.acSymbol.kind == CompletionKind.structName
				|| currentSymbol.acSymbol.kind == CompletionKind.unionName
				|| currentSymbol.acSymbol.kind == CompletionKind.className
				|| currentSymbol.acSymbol.kind == CompletionKind.interfaceName)
				kind = CompletionKind.memberVariableName;

			SemanticSymbol* symbol = allocateSemanticSymbol(
				declarator.name.text, kind,
				symbolFile, declarator.name.index);
			addTypeWithContext(symbol, dec.type);
			symbol.parent = currentSymbol;
			symbol.acSymbol.protection = protection.current;
			symbol.acSymbol.doc = makeDocumentation(declarator.comment);
			foldStringInitializer(declarator.initializer, symbol.acSymbol);
			currentSymbol.addChild(symbol, true);
			currentScope.addSymbol(symbol.acSymbol, false);

			if (currentSymbol.acSymbol.kind == CompletionKind.structName
				|| currentSymbol.acSymbol.kind == CompletionKind.unionName)
			{

				//{
				//	warning(symbol.acSymbol.name, " :::::: ", declarator.name.text, " ", protection.current);

				//	foreach(it; dec.storageClasses)
				//	{
				//		warning(it.token.type," ", it.token.text);
				//	}
				//}

				// Skip static fields (not instance members)
				import std.algorithm : any;
				if (!dec.storageClasses.any!(sc =>
					sc.token.type == tok!"static" ||
					sc.token.type == tok!"enum" ||
					sc.token.type == tok!"__gshared"))
				{

					structFieldNames.insert(symbol.acSymbol.name);
					// TODO: remove this cast. See the note on structFieldTypes
					structFieldTypes.insert(cast() dec.type);
					structFieldStatic.insert(false);
				}

			}

			auto lookup = symbol.typeLookups.front;
			//warning("## var: ", symbol.acSymbol.name);

			//if (declarator.initializer && declarator.initializer.nonVoidInitializer)
			//{
			//    auto nvi = declarator.initializer.nonVoidInitializer;
			//	if (auto une = cast(UnaryExpression) nvi.assignExpression)
			//	{
			//        // TODO: WATCH: this supports struct initializers, but might introduce bugs
			//        if (une.primaryExpression)
			//        {
			//            auto pe = une.primaryExpression;

			//            if (pe.functionLiteralExpression)
			//            {
			//                auto fle = pe.functionLiteralExpression;

			//                if (fle.specifiedFunctionBody)
			//                {
			//                    auto sfb = fle.specifiedFunctionBody;
			//                    if (sfb.blockStatement)
			//                    {
			//                        pushScope(sfb.blockStatement.startLocation, sfb.blockStatement.endLocation);

			//                        pushSymbol(WITH_SYMBOL_NAME, CompletionKind.withSymbol, symbolFile,
			//                                    currentScope.startLocation, dec.type);
			//                        popSymbol();

			//                        popScope();
			//                    }
			//                }
			//            }
			//        }

			//		auto fncall = une.functionCallExpression;
			//		if (fncall)
			//		{
			//			auto fnToken = fncall.tokens[$-1];


			//            //warning("    :", fnToken);

			//			//pushSymbol(fnToken.text, CompletionKind.functionName, symbolFile, fnToken.index);
			//			//scope (exit) popSymbol();

			//			//writeln("--2 ", fnToken.text);
			//			//foreach(it; fncall.tokens)
			//			//	writeln("   ", it.text);

			//			//if (fncall.arguments && fncall.arguments.namedArgumentList)
			//			//{
			//			//	processFunctionArgs(fncall.arguments);
			//			//}
			//		}
			//	}
			//}


		}
		if (dec.autoDeclaration !is null)
		{
			foreach (part; dec.autoDeclaration.parts)
			{
			SemanticSymbol* symbol = allocateSemanticSymbol(
				part.identifier.text, CompletionKind.variableName,
				symbolFile, part.identifier.index);
			symbol.parent = currentSymbol;
			populateInitializer(symbol, part.initializer);
			foldStringInitializer(part.initializer, symbol.acSymbol);
				symbol.acSymbol.protection = protection.current;
				symbol.acSymbol.doc = makeDocumentation(dec.comment);
				currentSymbol.addChild(symbol, true);
				currentScope.addSymbol(symbol.acSymbol, false);

				if (currentSymbol.acSymbol.kind == CompletionKind.structName
					|| currentSymbol.acSymbol.kind == CompletionKind.unionName)
				{

					//{
					//	warning(symbol.acSymbol.name, " :::::: ", part.identifier.text, " ", protection.current);

					//	foreach(it; dec.storageClasses)
					//	{
					//		warning(it.token.type," ", it.token.text);
					//	}
					//}

					 //Skip static fields (not instance members)
					import std.algorithm : any;
					if (!dec.storageClasses.any!(sc =>
						sc.token.type == tok!"static" ||
						sc.token.type == tok!"enum" ||
						sc.token.type == tok!"__gshared"))
					{
						structFieldNames.insert(symbol.acSymbol.name);
						// TODO: remove this cast. See the note on structFieldTypes
						structFieldTypes.insert(cast() dec.type);
						structFieldStatic.insert(true);
					}


				}

			}
		}
	}

	override void visit(const AliasDeclaration aliasDeclaration)
	{
		if (aliasDeclaration.initializers.length == 0)
		{
			foreach (name; aliasDeclaration.declaratorIdentifierList.identifiers)
			{
				SemanticSymbol* symbol = allocateSemanticSymbol(
					name.text, CompletionKind.aliasName, symbolFile, name.index);
				if (aliasDeclaration.type !is null)
					addTypeToLookups(symbol.typeLookups, aliasDeclaration.type);
				symbol.parent = currentSymbol;
				currentSymbol.addChild(symbol, true);
				currentScope.addSymbol(symbol.acSymbol, false);
				symbol.acSymbol.protection = protection.current;
				symbol.acSymbol.doc = makeDocumentation(aliasDeclaration.comment);
			}
		}
		else
		{
			foreach (initializer; aliasDeclaration.initializers)
			{
				SemanticSymbol* symbol = allocateSemanticSymbol(
					initializer.name.text, CompletionKind.aliasName,
					symbolFile, initializer.name.index);
				if (initializer.type !is null)
					addTypeToLookups(symbol.typeLookups, initializer.type);
				symbol.parent = currentSymbol;
				currentSymbol.addChild(symbol, true);
				currentScope.addSymbol(symbol.acSymbol, false);
				symbol.acSymbol.protection = protection.current;
				symbol.acSymbol.doc = makeDocumentation(aliasDeclaration.comment);
			}
		}
	}

	override void visit(const AliasThisDeclaration dec)
	{
		const k = currentSymbol.acSymbol.kind;
		if (k != CompletionKind.structName && k != CompletionKind.className &&
			k != CompletionKind.unionName && k != CompletionKind.mixinTemplateName)
		{
			return;
		}
		auto lookup = TypeLookupsAllocator.instance.make!TypeLookup(TypeLookupKind.aliasThis);
		lookup.astNode = dec;
		currentSymbol.typeLookups.insert(lookup);
	}

	override void visit(const Declaration dec)
	{
		//warning("  Declaration: ", dec);
		if (dec.attributeDeclaration !is null
			&& isProtection(dec.attributeDeclaration.attribute.attribute.type))
		{
			protection.addScope(dec.attributeDeclaration.attribute.attribute.type);
			return;
		}
		IdType p;
		foreach (const Attribute attr; dec.attributes)
		{
			if (isProtection(attr.attribute.type))
				p = attr.attribute.type;
		}
		if (p != tok!"")
		{
			protection.beginLocal(p);
			if (dec.declarations.length > 0)
			{
				protection.beginScope();
				dec.accept(this);
				protection.endScope();
			}
			else
				dec.accept(this);
			protection.endLocal();
		}
		else
			dec.accept(this);
	}

	override void visit(const Module mod)
	{
		rootSymbol = allocateSemanticSymbol(null, CompletionKind.moduleName,
			symbolFile);
		currentSymbol = rootSymbol;
		moduleScope = GCAllocator.instance.make!Scope(0, uint.max);
		currentScope = moduleScope;
		auto objectLocation = cache.resolveImportLocation!(true)("object");
		if (objectLocation is null)
			warning("Could not locate object.d or object.di");
		else
		{
			auto objectImport = allocateSemanticSymbol(IMPORT_SYMBOL_NAME,
				CompletionKind.importSymbol, objectLocation);
			objectImport.acSymbol.skipOver = true;
			currentSymbol.addChild(objectImport, true);
			currentScope.addSymbol(objectImport.acSymbol, false);
		}
		foreach (s; builtinSymbols[])
			currentScope.addSymbol(s, false);
		mod.accept(this);
	}

	override void visit(const EnumDeclaration dec)
	{
		assert (currentSymbol);
		SemanticSymbol* symbol = allocateSemanticSymbol(dec.name.text,
			CompletionKind.enumName, symbolFile, dec.name.index);
		if (dec.type !is null)
			addTypeToLookups(symbol.typeLookups, dec.type);
		symbol.acSymbol.addChildren(enumSymbols[], false);
		symbol.parent = currentSymbol;
		currentSymbol.addChild(symbol, true);
		currentScope.addSymbol(symbol.acSymbol, false);
		symbol.acSymbol.doc = makeDocumentation(dec.comment);

		istring lastComment = this.lastComment;
		this.lastComment = istring.init;
		scope(exit) this.lastComment = lastComment;

		currentSymbol = symbol;

		if (dec.enumBody !is null)
		{
			pushScope(dec.enumBody.startLocation, dec.enumBody.endLocation);
			dec.enumBody.accept(this);
			popScope();

			currentSymbol.acSymbol.location_end = dec.enumBody.endLocation;
		}

		currentSymbol = currentSymbol.parent;
	}

	mixin visitEnumMember!EnumMember;
	mixin visitEnumMember!AnonymousEnumMember;

	override void visit(const ModuleDeclaration moduleDeclaration)
	{
		const parts = moduleDeclaration.moduleName.identifiers;
		rootSymbol.acSymbol.name = internString(parts.length ? parts[$ - 1].text : null);


		string ct = "module ";
		foreach(i, it; parts)
		{
			ct ~= it.text;
			if (i != parts.length-1) ct ~= ".";
		}
		ct ~= ";";
		rootSymbol.acSymbol.callTip = istring(ct);
	}

	override void visit(const StructBody structBody)
	{
		import std.algorithm : move;

		pushScope(structBody.startLocation, structBody.endLocation);
		scope (exit) popScope();
		protection.beginScope();
		scope (exit) protection.endScope();


		currentSymbol.acSymbol.location_end = structBody.endLocation;

		auto savedStructFieldNames = move(structFieldNames);
		auto savedStructFieldTypes = move(structFieldTypes);
		auto savedStructFieldStatic = move(structFieldStatic);
		scope(exit) structFieldNames = move(savedStructFieldNames);
		scope(exit) structFieldTypes = move(savedStructFieldTypes);
		scope(exit) structFieldStatic = move(savedStructFieldStatic);

		DSymbol* thisSymbol = GCAllocator.instance.make!DSymbol(THIS_SYMBOL_NAME,
			CompletionKind.variableName, currentSymbol.acSymbol);
		thisSymbol.location = currentScope.startLocation;
		thisSymbol.location_end = currentScope.endLocation;
		thisSymbol.symbolFile = symbolFile;
		thisSymbol.type = currentSymbol.acSymbol;
		thisSymbol.ownType = false;
		currentScope.addSymbol(thisSymbol, false);

		foreach (dec; structBody.declarations)
			visit(dec);

		// If no constructor is found, generate one
		if ((currentSymbol.acSymbol.kind == CompletionKind.structName
				|| currentSymbol.acSymbol.kind == CompletionKind.unionName)
				&& currentSymbol.acSymbol.getFirstPartNamed(CONSTRUCTOR_SYMBOL_NAME) is null)
			createConstructor();

		if (currentSymbol.acSymbol.kind == CompletionKind.structName
				|| currentSymbol.acSymbol.kind == CompletionKind.unionName)
			createCallTip();
	}

	override void visit(const ImportDeclaration importDeclaration)
	{
		import std.algorithm : filter, map;
		import std.path : buildPath;
		import std.typecons : Tuple;

		foreach (single; importDeclaration.singleImports.filter!(
			a => a !is null && a.identifierChain !is null))
		{
			immutable importPath = convertChainToImportPath(single.identifierChain);
			istring modulePath = cache.resolveImportLocation(importPath);
			if (modulePath is null)
			{
				warning("Could not resolve location of module '", importPath.data, "'");
				continue;
			}

			//warning("### import: ", importPath," ", modulePath," ", protection.currentForImport == tok!"public");
			SemanticSymbol* importSymbol = allocateSemanticSymbol(IMPORT_SYMBOL_NAME, CompletionKind.importSymbol, modulePath);
			importSymbol.acSymbol.skipOver = protection.currentForImport != tok!"public";
			if (single.rename == tok!"")
			{
				size_t i = 0;
				DSymbol* currentImportSymbol;
				foreach (p; single.identifierChain.identifiers.map!(a => a.text))
				{
					immutable bool first = i == 0;
					immutable bool last = i + 1 >= single.identifierChain.identifiers.length;
					immutable CompletionKind kind = last ? CompletionKind.moduleName
						: CompletionKind.packageName;
					istring ip = internString(p);
					if (first)
					{
						auto s = currentScope.getSymbolsByName(ip);
						if (s.length == 0)
						{
							currentImportSymbol = GCAllocator.instance.make!DSymbol(ip, kind);
							currentScope.addSymbol(currentImportSymbol, true);
							if (last)
							{
								currentImportSymbol.symbolFile = modulePath;
								currentImportSymbol.type = importSymbol.acSymbol;
								currentImportSymbol.ownType = false;
							}
						}
						else
							currentImportSymbol = s[0];
					}
					else
					{
						auto s = currentImportSymbol.getPartsByName(ip);
						if (s.length == 0)
						{
							auto sym = GCAllocator.instance.make!DSymbol(ip, kind);
							currentImportSymbol.addChild(sym, true);
							currentImportSymbol = sym;
							if (last)
							{
								currentImportSymbol.symbolFile = modulePath;
								currentImportSymbol.type = importSymbol.acSymbol;
								currentImportSymbol.ownType = false;
							}
						}
						else
							currentImportSymbol = s[0];
					}
					i++;
				}
				currentSymbol.addChild(importSymbol, true);
				currentScope.addSymbol(importSymbol.acSymbol, false);
			}
			else
			{
				SemanticSymbol* renameSymbol = allocateSemanticSymbol(
					internString(single.rename.text), CompletionKind.aliasName,
					modulePath);
				renameSymbol.acSymbol.skipOver = protection.currentForImport != tok!"public";
				renameSymbol.acSymbol.type = importSymbol.acSymbol;
				renameSymbol.acSymbol.ownType = true;
				renameSymbol.addChild(importSymbol, true);
				currentSymbol.addChild(renameSymbol, true);
				currentScope.addSymbol(renameSymbol.acSymbol, false);
			}
			if (entry !is null)
				entry.dependencies.insert(modulePath);
		}
		if (importDeclaration.importBindings is null) return;
		if (importDeclaration.importBindings.singleImport.identifierChain is null) return;

		immutable chain = convertChainToImportPath(importDeclaration.importBindings.singleImport.identifierChain);
		istring modulePath = cache.resolveImportLocation(chain);
		if (modulePath is null)
		{
			warning("Could not resolve location of module '", chain, "'");
			return;
		}

		foreach (bind; importDeclaration.importBindings.importBinds)
		{
			TypeLookup* lookup = TypeLookupsAllocator.instance.make!TypeLookup(
				TypeLookupKind.selectiveImport);

			immutable bool isRenamed = bind.right != tok!"";
			lookup.selectiveImportRenamed = isRenamed;
			lookup.selectiveImportName = internString(isRenamed ? bind.right.text : bind.left.text);

			// The second phase must change this `importSymbol` kind to
			// `aliasName` for symbol lookup to work.
			SemanticSymbol* importSymbol = allocateSemanticSymbol(
				isRenamed ? bind.left.text : IMPORT_SYMBOL_NAME,
				CompletionKind.importSymbol, modulePath);

			if (isRenamed)
			{
				importSymbol.acSymbol.location = bind.left.index;
				importSymbol.acSymbol.altFile = symbolFile;
			}

			importSymbol.acSymbol.qualifier = SymbolQualifier.selectiveImport;
			importSymbol.typeLookups.insert(lookup);
			importSymbol.acSymbol.skipOver = protection.currentForImport != tok!"public";
			currentSymbol.addChild(importSymbol, true);
			currentScope.addSymbol(importSymbol.acSymbol, false);
		}

		if (entry !is null)
			entry.dependencies.insert(modulePath);
	}

	// Create scope for block statements
	override void visit(const BlockStatement blockStatement)
	{
		//warning("    BlockStatement");
		if (blockStatement.declarationsAndStatements !is null)
		{
			pushScope(blockStatement.startLocation, blockStatement.endLocation);
			scope(exit) popScope();
			visit (blockStatement.declarationsAndStatements);
		}
	}

	// Create attribute/protection scope for conditional compilation declaration
	// blocks.
	override void visit(const ConditionalDeclaration conditionalDecl)
	{
		if (conditionalDecl.compileCondition !is null)
			visit(conditionalDecl.compileCondition);

		if (conditionalDecl.trueDeclarations.length)
		{
			protection.beginScope();
			scope (exit) protection.endScope();

			foreach (decl; conditionalDecl.trueDeclarations)
				if (decl !is null)
					visit (decl);
		}

		if (conditionalDecl.falseDeclarations.length)
		{
			protection.beginScope();
			scope (exit) protection.endScope();

			foreach (decl; conditionalDecl.falseDeclarations)
				if (decl !is null)
					visit (decl);
		}
	}

	override void visit(const TemplateMixinExpression tme)
	{
		// TODO: support typeof here
		if (tme.mixinTemplateName.symbol is null)
			return;
		const Symbol sym = tme.mixinTemplateName.symbol;
		auto lookup = TypeLookupsAllocator.instance.make!TypeLookup(TypeLookupKind.mixinTemplate);

		lookup.astNode = sym.identifierOrTemplateChain;

		if (currentSymbol.acSymbol.kind != CompletionKind.functionName)
			currentSymbol.typeLookups.insert(lookup);

		/* If the mixin is named then do like if `mixin F f;` would be `mixin F; alias f = F;`
		which's been empirically verified to produce the right completions for `f.`,
		*/
		if (tme.identifier != tok!"" && sym.identifierOrTemplateChain &&
			sym.identifierOrTemplateChain.identifiersOrTemplateInstances.length)
		{
			SemanticSymbol* symbol = allocateSemanticSymbol(tme.identifier.text,
				CompletionKind.aliasName, symbolFile, tme.identifier.index);
			Type tp = TypeLookupsAllocator.instance.make!Type;
			tp.type2 = TypeLookupsAllocator.instance.make!Type2;
			TypeIdentifierPart root;
			TypeIdentifierPart current;
			foreach(ioti; sym.identifierOrTemplateChain.identifiersOrTemplateInstances)
			{
				TypeIdentifierPart old = current;
				current = TypeLookupsAllocator.instance.make!TypeIdentifierPart;
				if (old)
				{
					old.typeIdentifierPart = current;
				}
				else
				{
					root = current;
				}
				current.identifierOrTemplateInstance = cast() ioti;
			}
			tp.type2.typeIdentifierPart = root;
			addTypeToLookups(symbol.typeLookups, tp);
			symbol.parent = currentSymbol;
			currentSymbol.addChild(symbol, true);
			currentScope.addSymbol(symbol.acSymbol, false);
			symbol.acSymbol.protection = protection.current;
		}
	}

	override void visit(const ForeachStatement feStatement)
	{
		if (feStatement.declarationOrStatement !is null
			&& feStatement.declarationOrStatement.statement !is null
			&& feStatement.declarationOrStatement.statement.statementNoCaseNoDefault !is null
			&& feStatement.declarationOrStatement.statement.statementNoCaseNoDefault.blockStatement !is null)
		{
			const BlockStatement bs =
				feStatement.declarationOrStatement.statement.statementNoCaseNoDefault.blockStatement;
			pushScope(feStatement.startIndex, bs.endLocation);
			scope(exit) popScope();
			feExpression = feStatement.low.items[$ - 1];
			feStatement.accept(this);
			feExpression = null;
		}
		else
		{
			const ubyte o1 = foreachTypeIndexOfInterest;
			const ubyte o2 = foreachTypeIndex;
			feStatement.accept(this);
			foreachTypeIndexOfInterest = o1;
			foreachTypeIndex = o2;
		}
	}

	override void visit(const ForeachTypeList feTypeList)
	{
		foreachTypeIndex = 0;
		foreachTypeIndexOfInterest = cast(ubyte)(feTypeList.items.length - 1);
		feTypeList.accept(this);
	}

	override void visit(const ForeachType feType)
	{
		if (foreachTypeIndex++ == foreachTypeIndexOfInterest)
		{
			SemanticSymbol* symbol = allocateSemanticSymbol(feType.identifier.text,
				CompletionKind.variableName, symbolFile, feType.identifier.index);
			if (feType.type !is null)
				addTypeToLookups(symbol.typeLookups, feType.type);
			symbol.parent = currentSymbol;
			currentSymbol.addChild(symbol, true);
			currentScope.addSymbol(symbol.acSymbol, true);
			if (symbol.typeLookups.empty && feExpression !is null)
				populateInitializer(symbol, feExpression, true);
		}
	}

	/**
	 * Records the first `return` expression of the enclosing function.
	 *
	 * An `auto` function's type comes from that expression, and the body walk
	 * that reaches this statement is already happening, so the record costs an
	 * assignment per `return` (walking the body again just to find them would
	 * cost a traversal per `auto` function, and Phobos is full of them).
	 * Nested functions and function literals are visited with their own
	 * `currentSymbol`, so each records its own returns.
	 */
	override void visit(const ReturnStatement statement)
	{
		if (statement.expression !is null
			&& currentSymbol !is null
			&& currentSymbol.acSymbol.kind == CompletionKind.functionName
			&& currentSymbol.autoReturnExpression is null)
			// The AST is read-only; the reference is stored to be resolved
			// after the body walk.
			currentSymbol.autoReturnExpression = cast(Expression) statement.expression;
		statement.accept(this);
	}

	override void visit(const IfStatement ifs)
	{
		if (ifs.condition && ifs.condition.identifier != tok!"" && ifs.thenStatement)
		{
			pushScope(ifs.thenStatement.startLocation, ifs.thenStatement.endLocation);
			scope(exit) popScope();

			SemanticSymbol* symbol = allocateSemanticSymbol(ifs.condition.identifier.text,
				CompletionKind.variableName, symbolFile, ifs.condition.identifier.index);
			if (ifs.condition !is null && ifs.condition.type !is null)
				addTypeToLookups(symbol.typeLookups, ifs.condition.type);
			symbol.parent = currentSymbol;
			currentSymbol.addChild(symbol, true);
			currentScope.addSymbol(symbol.acSymbol, true);
			if (symbol.typeLookups.empty && ifs.condition !is null && ifs.condition.expression !is null)
				populateInitializer(symbol, ifs.condition.expression, false);
		}
		ifs.accept(this);
	}

	override void visit(const WithStatement withStatement)
	{
		if (withStatement.expression !is null
			&& withStatement.declarationOrStatement !is null)
		{
			pushScope(withStatement.declarationOrStatement.startLocation,
				withStatement.declarationOrStatement.endLocation);
			scope(exit) popScope();

			pushSymbol(WITH_SYMBOL_NAME, CompletionKind.withSymbol, symbolFile,
				currentScope.startLocation, null);
			scope(exit) popSymbol();

			populateInitializer(currentSymbol, withStatement.expression, false);
			withStatement.accept(this);

		}
		else
			withStatement.accept(this);
	}

	static foreach (T; AliasSeq!(ArgumentList, NamedArgumentList))
		override void visit(const T list)
		{
			scope visitor = new ArgumentListVisitor(this);
			visitor.visit(list);
		}

	alias visit = ASTVisitor.visit;

	/// Module scope
	Scope* moduleScope;

	/// The module
	SemanticSymbol* rootSymbol;

	/// Number of symbols allocated
	uint symbolsAllocated;

private:

	void createConstructor()
	{
		import std.range : zip;

		// ctor
		{
			auto app = appender!string();
			app.put("this(");
			bool first = true;
			foreach (field; zip(structFieldTypes[], structFieldNames[], structFieldStatic[]))
			{
				if (field[2] == true) continue;

				if (first)
					first = false;
				else
					app.put(", ");
				if (field[0] is null)
					app.put("auto ");
				else
				{
					app.formatNode(field[0]);
					app.put(" ");
				}
				app.put(field[1].data);
			}
			app.put(")");
			SemanticSymbol* symbol = allocateSemanticSymbol(CONSTRUCTOR_SYMBOL_NAME,
				CompletionKind.functionName, symbolFile, currentSymbol.acSymbol.location);
			symbol.acSymbol.callTip = istring(app.data);
			symbol.acSymbol.generated = true;
			currentSymbol.addChild(symbol, true);
		}
	}

	void createCallTip()
	{
		import std.range : zip;

		auto app = appender!string();

		switch (currentSymbol.acSymbol.kind)
		{
			case CompletionKind.structName: app.put("struct "); break;
			case CompletionKind.unionName: app.put("union "); break;

			default: app.put("auto ");
		}

		app.put(currentSymbol.acSymbol.name.data);
		if (currentAggregateTemplateParameters !is null)
			app.formatNode(currentAggregateTemplateParameters);
		app.put(" {\n");
		foreach (field; zip(structFieldTypes[], structFieldNames[], structFieldStatic[]))
		{
			if (field[2] == true) continue;

			if (field[0] is null)
				app.put("    auto ");
			else
			{
				app.put("    ");
				app.formatNode(field[0]);
				app.put(" ");
			}
			app.put(field[1].data);
			app.put(";\n");
		}

		bool first = false;
		foreach (field; zip(structFieldTypes[], structFieldNames[], structFieldStatic[]))
		{
			if (field[2] == false) continue;
			if (!first)
			{
				app.put("    // static fields\n");
				first = true;
			}

			if (field[0] is null)
				app.put("    auto ");
			else
			{
				app.put("    ");
				app.formatNode(field[0]);
				app.put(" ");
			}
			app.put(field[1].data);
			app.put(";\n");
		}

		app.put("}");
		currentSymbol.acSymbol.callTip = istring(app.data);
	}

	void pushScope(size_t startLocation, size_t endLocation)
	{
		//writeln("> pushScope: ", startLocation, ":", endLocation);
		assert (startLocation < uint.max);
		assert (endLocation < uint.max || endLocation == size_t.max);
		Scope* s = GCAllocator.instance.make!Scope(cast(uint) startLocation, cast(uint) endLocation);
		s.parent = currentScope;
		currentScope.children.insert(s);
		currentScope = s;
	}

	void popScope()
	{
		currentScope = currentScope.parent;
	}

	void pushFunctionScope(const FunctionBody functionBody, size_t scopeBegin)
	{
		//writeln("> pushFnScope: ", scopeBegin);
		Scope* s = GCAllocator.instance.make!Scope(cast(uint) scopeBegin,
			cast(uint) functionBody.endLocation);
		s.parent = currentScope;
		currentScope.children.insert(s);
		currentScope = s;
	}

	void pushSymbol(string name, CompletionKind kind, istring symbolFile,
		size_t location = 0, const Type type = null)
	{
		SemanticSymbol* symbol = allocateSemanticSymbol(name, kind, symbolFile,
			location);
		if (type !is null)
			addTypeToLookups(symbol.typeLookups, type);
		symbol.parent = currentSymbol;
		currentSymbol.addChild(symbol, true);
		currentScope.addSymbol(symbol.acSymbol, false);
		currentSymbol = symbol;
	}

	void popSymbol()
	{
		currentSymbol = currentSymbol.parent;
	}

	template visitEnumMember(T)
	{
		override void visit(const T member)
		{
			pushSymbol(member.name.text, CompletionKind.enumMember, symbolFile,
				member.name.index, member.type);
			scope(exit) popSymbol();
			currentSymbol.acSymbol.doc = makeDocumentation(member.comment);
			if (currentSymbol.parent && (currentSymbol.parent.acSymbol.kind == CompletionKind.enumName))
				currentSymbol.acSymbol.type = currentSymbol.parent.acSymbol;
		}
	}

	void visitAggregateDeclaration(AggType)(AggType dec, CompletionKind kind)
	{
		static if (__traits(hasMember, AggType, "variableName"))
		{
			if ((kind == CompletionKind.unionName || kind == CompletionKind.structName) &&
				dec.name == tok!"")
			{
				if (dec.variableName != tok!"")
				{
					handleAnonStructVariable(dec, kind);
					return;
				}
				dec.accept(this);
				return;
			}
		}
		else
		{
			if ((kind == CompletionKind.unionName || kind == CompletionKind.structName) &&
				dec.name == tok!"")
			{
				dec.accept(this);
				return;
			}
		}

		// Skip forward declarations for structs and unions (struct Foo; / union Foo;)
		// only process full definitions, otherwise it'll overwrite the useful one,
		// and dmd -H has the tendency to generate a lot of them specially with ImportC
		static if (!is(AggType == const(TemplateDeclaration)))
		{
			if (dec.structBody is null && 
				(kind == CompletionKind.structName || kind == CompletionKind.unionName))
				return;
		}

		pushSymbol(dec.name.text, kind, symbolFile, dec.name.index);
		scope(exit) popSymbol();

		if (kind == CompletionKind.className)
			currentSymbol.acSymbol.addChildren(classSymbols[], false);
		else
			currentSymbol.acSymbol.addChildren(aggregateSymbols[], false);
		currentSymbol.acSymbol.protection = protection.current;
		currentSymbol.acSymbol.doc = makeDocumentation(dec.comment);

		istring lastComment = this.lastComment;
		this.lastComment = istring.init;
		scope(exit) this.lastComment = lastComment;

		immutable size_t scopeBegin = dec.name.index + dec.name.text.length;
		static if (is (AggType == const(TemplateDeclaration)))
			immutable size_t scopeEnd = dec.endLocation;
		else
			immutable size_t scopeEnd = dec.structBody is null ? scopeBegin : dec.structBody.endLocation;

		pushScope(scopeBegin, scopeEnd);
		scope(exit) popScope();
		protection.beginScope();
		scope (exit) protection.endScope();
		processTemplateParameters(currentSymbol, dec.templateParameters);

		auto savedAggregateTemplateParameters = currentAggregateTemplateParameters;
		currentAggregateTemplateParameters = dec.templateParameters;
		scope(exit) currentAggregateTemplateParameters = savedAggregateTemplateParameters;

		dec.accept(this);
	}

	void handleAnonStructVariable(AggType)(AggType dec, CompletionKind kind)
	{
		import std.format : format;
		__gshared size_t anonStructIndex;
		const idt = internString("__anonstruct%d".format(++anonStructIndex));

		SemanticSymbol* anonSym = allocateSemanticSymbol(idt, kind,
			symbolFile, dec.structBody.startLocation);
		anonSym.acSymbol.addChildren(aggregateSymbols[], false);
		anonSym.acSymbol.protection = protection.current;
		anonSym.acSymbol.doc = makeDocumentation(dec.comment);
		anonSym.parent = currentSymbol;
		anonSym.acSymbol.generated = true;
		currentSymbol.addChild(anonSym, true);

		SemanticSymbol* savedCurrent = currentSymbol;
		currentSymbol = anonSym;

		visit(dec.structBody);

		currentSymbol = savedCurrent;

		CompletionKind varKind = CompletionKind.variableName;
		if (currentSymbol.acSymbol.kind == CompletionKind.structName
			|| currentSymbol.acSymbol.kind == CompletionKind.unionName
			|| currentSymbol.acSymbol.kind == CompletionKind.className
			|| currentSymbol.acSymbol.kind == CompletionKind.interfaceName)
			varKind = CompletionKind.memberVariableName;

		SemanticSymbol* varSymbol = allocateSemanticSymbol(
			dec.variableName.text, varKind,
			symbolFile, dec.variableName.index);
		varSymbol.acSymbol.type = anonSym.acSymbol;
		varSymbol.parent = currentSymbol;
		varSymbol.acSymbol.protection = protection.current;
		currentSymbol.addChild(varSymbol, true);
		currentScope.addSymbol(varSymbol.acSymbol, false);

		if (currentSymbol.acSymbol.kind == CompletionKind.structName
			|| currentSymbol.acSymbol.kind == CompletionKind.unionName)
		{
			structFieldNames.insert(varSymbol.acSymbol.name);
			structFieldTypes.insert(null);
			structFieldStatic.insert(false);
		}
	}

	void visitConstructor(size_t location, const Parameters parameters,
		const TemplateParameters templateParameters,
		const FunctionBody functionBody, string doc)
	{
		SemanticSymbol* symbol = allocateSemanticSymbol(CONSTRUCTOR_SYMBOL_NAME,
			CompletionKind.functionName, symbolFile, location);
		symbol.parent = currentSymbol;
		currentSymbol.addChild(symbol, true);
		symbol.acSymbol.protection = protection.current;
		symbol.acSymbol.doc = makeDocumentation(doc);

		istring lastComment = this.lastComment;
		this.lastComment = istring.init;
		scope(exit) this.lastComment = lastComment;

		if (functionBody !is null)
		{
			pushFunctionScope(functionBody, location + 4); // 4 == "this".length
			scope(exit) popScope();
			currentSymbol = symbol;
			processParameters(symbol, null, THIS_SYMBOL_NAME, parameters, templateParameters);
			functionBody.accept(this);
			currentSymbol = currentSymbol.parent;
		}
		else
		{
			currentSymbol = symbol;
			processParameters(symbol, null, THIS_SYMBOL_NAME, parameters, templateParameters);
			currentSymbol = currentSymbol.parent;
		}
	}

	void visitDestructor(size_t location, const FunctionBody functionBody, string doc)
	{
		SemanticSymbol* symbol = allocateSemanticSymbol(DESTRUCTOR_SYMBOL_NAME,
			CompletionKind.functionName, symbolFile, location);
		symbol.parent = currentSymbol;
		currentSymbol.addChild(symbol, true);
		symbol.acSymbol.callTip = internString("~this()");
		symbol.acSymbol.protection = protection.current;
		symbol.acSymbol.doc = makeDocumentation(doc);

		istring lastComment = this.lastComment;
		this.lastComment = istring.init;
		scope(exit) this.lastComment = lastComment;

		if (functionBody !is null)
		{
			pushFunctionScope(functionBody, location + 4); // 4 == "this".length
			scope(exit) popScope();
			currentSymbol = symbol;
			functionBody.accept(this);
			currentSymbol = currentSymbol.parent;
		}
	}

	void processParameters(SemanticSymbol* symbol, const Type returnType,
		string functionName, const Parameters parameters,
		const TemplateParameters templateParameters)
	{
		processTemplateParameters(symbol, templateParameters);
		if (parameters !is null)
		{
			currentSymbol.acSymbol.functionParameters.reserve(parameters.parameters.length);
			foreach (const Parameter p; parameters.parameters)
			{
				//warning("process param: ", p.name.text, p.default_);
				SemanticSymbol* parameter = allocateSemanticSymbol(
					p.name.text, CompletionKind.variableName, symbolFile,
					p.name.index);
				addTypeWithContext(parameter, p.type);
				parameter.parent = currentSymbol;
				foreach (const attribute; p.parameterAttributes)
				{
					switch (attribute.idType)
					{
					case tok!"ref":
						if (!parameter.acSymbol.parameterIsAutoRef)
							parameter.acSymbol.parameterIsRef = true;
						break;
					case tok!"auto":
						// assume this is `auto ref`, since otherwise `auto` is
						// not a valid parameter attribute.
						if (!parameter.acSymbol.parameterIsRef)
							parameter.acSymbol.parameterIsAutoRef = true;
						break;
					case tok!"scope":
						parameter.acSymbol.parameterIsScope = true;
						break;
					case tok!"return":
						parameter.acSymbol.parameterIsReturn = true;
						break;
					case tok!"lazy":
						parameter.acSymbol.parameterIsLazy = true;
						break;
					case tok!"out":
						parameter.acSymbol.parameterIsOut = true;
						break;
					case tok!"in":
						parameter.acSymbol.parameterIsIn = true;
						break;
					case tok!"const":
						parameter.acSymbol.parameterIsConst = true;
						break;
					case tok!"immutable":
						parameter.acSymbol.parameterIsImmutable = true;
						break;
					case tok!"shared":
						parameter.acSymbol.parameterIsShared = true;
						break;
					case tok!"inout":
						parameter.acSymbol.parameterIsInout = true;
						break;
					default:
						break;
					}
				}
				//currentSymbol.acSymbol.argNames.insert(parameter.acSymbol.name);

				currentSymbol.acSymbol.functionParameters ~= parameter.acSymbol;

				currentSymbol.addChild(parameter, true);
				currentScope.addSymbol(parameter.acSymbol, false);
			}
			if (parameters.hasVarargs)
			{
				SemanticSymbol* argptr = allocateSemanticSymbol(ARGPTR_SYMBOL_NAME,
					CompletionKind.variableName, istring(null), size_t.max);
				addTypeToLookups(argptr.typeLookups, argptrType);
				argptr.parent = currentSymbol;
				currentSymbol.addChild(argptr, true);
				currentScope.addSymbol(argptr.acSymbol, false);

				SemanticSymbol* arguments = allocateSemanticSymbol(
					ARGUMENTS_SYMBOL_NAME, CompletionKind.variableName,
					istring(null), size_t.max);
				addTypeToLookups(arguments.typeLookups, argumentsType);
				arguments.parent = currentSymbol;
				currentSymbol.addChild(arguments, true);
				currentScope.addSymbol(arguments.acSymbol, false);
			}
		}
		symbol.acSymbol.callTip = formatCallTip(returnType, functionName,
			parameters, templateParameters);
	}

	void processTemplateParameters(SemanticSymbol* symbol, const TemplateParameters templateParameters)
	{
		if (templateParameters !is null
				&& templateParameters.templateParameterList !is null)
		{
			foreach (const TemplateParameter p; templateParameters.templateParameterList.items)
			{
				string name;
				CompletionKind kind;
				size_t index;
				Rebindable!(const(Type)) type;
				if (p.templateAliasParameter !is null)
				{
					name = p.templateAliasParameter.identifier.text;
					kind = CompletionKind.aliasName;
					index = p.templateAliasParameter.identifier.index;
				}
				else if (p.templateTypeParameter !is null)
				{
					name = p.templateTypeParameter.identifier.text;
					kind = CompletionKind.aliasName;
					index = p.templateTypeParameter.identifier.index;
					// even if templates are not solved we can get the completions
					// for the type the template parameter implicitly converts to,
					// which is often useful for aggregate types.
					if (p.templateTypeParameter.colonType)
						type = p.templateTypeParameter.colonType;
					// otherwise just provide standard type properties
					else
						kind = CompletionKind.typeTmpParam;

					//writeln("# ", name, " kind: ", kind, " index: ", index);
				}
				else if (p.templateValueParameter !is null)
				{
					name = p.templateValueParameter.identifier.text;
					kind = CompletionKind.variableName;
					index = p.templateValueParameter.identifier.index;
					type = p.templateValueParameter.type;
				}
				else if (p.templateTupleParameter !is null)
				{
					name = p.templateTupleParameter.identifier.text;
					kind = CompletionKind.variadicTmpParam;
					index = p.templateTupleParameter.identifier.index;
				}
				else
					continue;
				SemanticSymbol* templateParameter = allocateSemanticSymbol(name,
					kind, symbolFile, index);
				symbol.acSymbol.qualifier = SymbolQualifier.templated;
				if (type !is null)
					addTypeToLookups(templateParameter.typeLookups, type);

				if (p.templateTupleParameter !is null)
				{
					// The parameter's type is the dedicated `typeTmpParamSymbol`
					// (set by `secondPass`), so this lookup carries no node.
					TypeLookup* tl = TypeLookupsAllocator.instance.make!TypeLookup(
						TypeLookupKind.varOrFunType);
					templateParameter.typeLookups.insert(tl);
				}
				else if (p.templateTypeParameter && kind == CompletionKind.typeTmpParam)
				{
					TypeLookup* tl = TypeLookupsAllocator.instance.make!TypeLookup(
						TypeLookupKind.varOrFunType);
					templateParameter.typeLookups.insert(tl);
				}

				templateParameter.parent = symbol;
				symbol.addChild(templateParameter, true);
				if (currentScope)
					currentScope.addSymbol(templateParameter.acSymbol, false);
			}
		}
	}

	istring formatCallTip(const Type returnType, string name,
		const Parameters parameters, const TemplateParameters templateParameters)
	{

		auto app = appender!string();
		if (returnType !is null)
		{
			app.formatNode(returnType);
			app.put(' ');
		}
		app.put(name);
		if (templateParameters !is null)
			app.formatNode(templateParameters);
		if (parameters is null)
			app.put("()");
		else
			app.formatNode(parameters);
		return istring(app.data);
	}

	void populateInitializer(T)(SemanticSymbol* symbol, const T initializer,
		bool appendForeach = false)
	{
		// A `foreach` aggregates a range (`foreach (x; rows)`), so the loop
		// variable's type is the aggregate's *element* type, which the resolver
		// has to step to.  That is a property of the lookup, not of the
		// expression, so it gets its own kind rather than a marker string.
		immutable kind = appendForeach ? TypeLookupKind.foreachElement
			: TypeLookupKind.initializer;
		auto lookup = TypeLookupsAllocator.instance.make!TypeLookup(kind);
		symbol.typeLookups.insert(lookup);

		// The initializer node itself -- an `Initializer` / `NonVoidInitializer`
		// wrapper, an `Expression`, or an expression node.  The resolver walks
		// it (unwrapping as needed) instead of the crumbs.
		lookup.astNode = initializer;
	}

	SemanticSymbol* allocateSemanticSymbol(string name, CompletionKind kind,
		istring symbolFile, size_t location = 0)
	{
		DSymbol* acSymbol = GCAllocator.instance.make!DSymbol(istring(name), kind);
		acSymbol.location = location;
		acSymbol.symbolFile = symbolFile;
		symbolsAllocated++;
		return GCAllocator.instance.make!SemanticSymbol(acSymbol);
	}

	/**
	 * Records a *declared* type: the `Type` node, which `second.d` walks
	 * (template arguments included -- they are read from the
	 * `TemplateInstance` node when the name is resolved).
	 */
	void addTypeWithContext(SemanticSymbol* symbol, const Type type)
	{
		if (type is null)
			return;

		// Reuse the lookup this declaration already has: a second lookup for
		// the same symbol is resolved *after* the first and overwrites its
		// result, which is how `TD!int make()` kept reporting `T` while a local
		// `TD!int x;` was fine.  One lookup keeps the node and the captured
		// arguments together.
		TypeLookup* lookup;
		foreach (candidate; symbol.typeLookups)
			if (candidate.kind == TypeLookupKind.varOrFunType)
			{
				lookup = cast(TypeLookup*) candidate;
				break;
			}

		if (lookup is null)
		{
			lookup = TypeLookupsAllocator.instance.make!TypeLookup(TypeLookupKind.varOrFunType);
			symbol.typeLookups.insert(lookup);
		}

		addTypeToLookups(symbol.typeLookups, type, lookup);
		// The declared type node: `resolveTypeFromType` walks it, template
		// arguments and all (they are read from the `TemplateInstance` node).
		// Only this producer asks for the instance to be applied -- the old
		// `VariableContext` capture lived here too.
		lookup.astNode = type;
		lookup.applyTypeInstance = true;
	}


	/**
	 * Records a declared type for the resolver: a single `varOrFunType`
	 * lookup whose `astNode` is the `Type` node.  Everything the old crumb
	 * encoding spelled out (the name chain, `this`/`super`, builtins, the
	 * `typeSuffixes`) `second.d` reads from that node now, so there is nothing
	 * to serialise here.
	 *
	 * When `l` is given the caller already owns a lookup for this symbol and
	 * has set its node (`addTypeWithContext`), so there is nothing to do.
	 */
	void addTypeToLookups(ref TypeLookups lookups, const Type type, TypeLookup* l = null)
	{
		if (l !is null || type is null)
			return;
		auto lookup = TypeLookupsAllocator.instance.make!TypeLookup(
			TypeLookupKind.varOrFunType);
		lookup.astNode = type;
		lookups.insert(lookup);
	}

	DocString makeDocumentation(string documentation)
	{
		if (documentation.isDitto)
			return DocString(lastComment);
		else
		{
			lastComment = internString(documentation);
			return DocString(lastComment);
		}
	}

	/// Current protection type
	ProtectionStack protection;

	/// Current scope
	Scope* currentScope;

	/// Current symbol
	SemanticSymbol* currentSymbol;

	/// Path to the file being converted
	istring symbolFile;

	/// Field types used for generating struct constructors if no constructor
	/// was defined
	// TODO: This should be `const Type`, but Rebindable and opEquals don't play
	// well together
	UnrolledList!(Type) structFieldTypes;
	/// Field names for struct constructor generation
	UnrolledList!(istring) structFieldNames;
	/// Wether they are static or not
	UnrolledList!(bool) structFieldStatic;

	/// Last comment for ditto-ing
	istring lastComment;

	/// The template parameter list of the struct/union currently being
	/// visited (`(T)` in `struct TD(T)`), read by `createCallTip()` once it
	/// reaches the closing brace - saved/restored the same way `lastComment`
	/// is, so a struct nested inside a templated one sees its own list, not
	/// the enclosing one's.
	Rebindable!(const TemplateParameters) currentAggregateTemplateParameters;

	const Module mod;

	Rebindable!(const ExpressionNode) feExpression;

	CacheEntry* entry;

	ModuleCache* cache;

	bool skipBaseClassesOfNewAnon;

	ubyte foreachTypeIndexOfInterest;
	ubyte foreachTypeIndex;
}

struct ProtectionStack
{
	invariant
	{
		import std.algorithm.iteration : filter, joiner, map;
		import std.conv:to;
		import std.range : walkLength;

		assert(stack.length == stack[].filter!(a => isProtection(a)
				|| a == tok!":" || a == tok!"{").walkLength(), to!string(stack[].map!(a => str(a)).joiner(", ")));
	}

	IdType currentForImport() const
	{
		return stack.empty ? tok!"default" : current();
	}

	IdType current() const
	{
		import std.algorithm.iteration : filter;
		import std.range : choose, only;

		IdType retVal;
		foreach (t; choose(stack.empty, only(tok!"public"), stack[]).filter!(
				a => a != tok!"{" && a != tok!":"))
			retVal = cast(IdType) t;
		return retVal;
	}

	void beginScope()
	{
		stack.insertBack(tok!"{");
	}

	void endScope()
	{
		import std.algorithm.iteration : joiner;
		import std.conv : to;
		import std.range : walkLength;

		while (!stack.empty && stack.back == tok!":")
		{
			assert(stack.length >= 2);
			stack.popBack();
			stack.popBack();
		}
		assert(stack.length == stack[].walkLength());
		assert(!stack.empty && stack.back == tok!"{", to!string(stack[].map!(a => str(a)).joiner(", ")));
		stack.popBack();
	}

	void beginLocal(const IdType t)
	{
		assert (t != tok!"", "DERP!");
		stack.insertBack(t);
	}

	void endLocal()
	{
		import std.algorithm.iteration : joiner;
		import std.conv : to;

		assert(!stack.empty && stack.back != tok!":" && stack.back != tok!"{",
				to!string(stack[].map!(a => str(a)).joiner(", ")));
		stack.popBack();
	}

	void addScope(const IdType t)
	{
		assert(t != tok!"", "DERP!");
		assert(isProtection(t));
		if (!stack.empty && stack.back == tok!":")
		{
			assert(stack.length >= 2);
			stack.popBack();
			assert(isProtection(stack.back));
			stack.popBack();
		}
		stack.insertBack(t);
		stack.insertBack(tok!":");
	}

private:

	UnrolledList!IdType stack;
}

void formatNode(A, T)(ref A appender, const T node)
{
	if (node is null)
		return;
	scope f = new Formatter!(A*)(&appender);
	f.format(node);
}

private:

bool isDitto(scope const(char)[] comment)
{
	import std.uni : icmp;

	return comment.length == 5 && icmp(comment, "ditto") == 0;
}

/// The last identifier of a `TypeIdentifierPart` chain (`a.b.c` -> `c`): the
/// name a base-class alias symbol takes.
istring lastTypeIdentifierName(const TypeIdentifierPart tip)
{
	istring last;
	for (auto part = cast(TypeIdentifierPart) tip; part !is null; part = part.typeIdentifierPart)
	{
		if (part.identifierOrTemplateInstance is null)
			continue;
		auto ioti = part.identifierOrTemplateInstance;
		if (ioti.identifier != tok!"")
			last = internString(ioti.identifier.text);
		else if (ioti.templateInstance !is null && ioti.templateInstance.identifier != tok!"")
			last = internString(ioti.templateInstance.identifier.text);
	}
	return last;
}


/// Records the value of `= "literal"` on the symbol, so later passes can fold
/// a manifest constant (`enum name = "bar"`) without re-reading the tree.
/// Only a single plain-quoted literal is folded; anything else leaves the
/// symbol's `constantValue` empty.
void foldStringInitializer(const Initializer init, DSymbol* symbol)
{
	if (init is null || init.nonVoidInitializer is null
		|| init.nonVoidInitializer.assignExpression is null)
		return;
	auto expr = init.nonVoidInitializer.assignExpression;
	if (expr.tokens.length != 1)
		return;
	auto t = expr.tokens[0];
	if (t.type != tok!"stringLiteral" && t.type != tok!"wstringLiteral"
		&& t.type != tok!"dstringLiteral")
		return;
	if (t.text.length < 2)
		return;
	immutable char q = t.text[0];
	if ((q != '"' && q != '\'' && q != '`') || t.text[$ - 1] != q)
		return;
	symbol.constantValue = internString(t.text[1 .. $ - 1]);
}

/// Public: also used from `dcd.server.dll` to resolve an import's module
/// path outside a `FirstPass` run (unused-import detection).
public static istring convertChainToImportPath(const IdentifierChain ic)
{
	import std.path : dirSeparator;
	auto app = appender!string();
	foreach (i, ident; ic.identifiers)
	{
		app.put(ident.text);
		if (i + 1 < ic.identifiers.length)
			app.put(dirSeparator);
	}
	return istring(app.data);
}

class ArgumentListVisitor : ASTVisitor
{
	this(FirstPass fp)
	{
		assert(fp);
		this.fp = fp;
	}

	alias visit = ASTVisitor.visit;

	override void visit(const FunctionLiteralExpression exp)
	{
		fp.visit(exp);
	}

	override void visit(const NewAnonClassExpression exp)
	{
		fp.visit(exp);
	}

private:
	FirstPass fp;
}
