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

module dsymbol.conversion.second;

public import dsymbol.conversion.second.instantiate : hasTemplateParameters,
	instantiateWithArguments;
public import dsymbol.conversion.second.declared_type : resolveTypeFromType;
public import dsymbol.conversion.second.initializer : BinaryKind, binaryResultTypeName,
	promotedScalarName, resolveTypeFromInitializer, typeSwap;
import dsymbol.conversion.second.inheritance : resolveInheritance, resolveAliasThis,
	resolveMixinTemplates;
import dsymbol.conversion.second.declared_type : aliasNeedsRetry;
import dsymbol.semantic;
import dsymbol.string_interning;
import dsymbol.symbol;
import dsymbol.scope_;
import dsymbol.builtin.symbols;
import dsymbol.type_lookup;
import dsymbol.deferred;
import dsymbol.modulecache;
import std.experimental.allocator;
import std.experimental.logger;

void secondPass(SemanticSymbol* rootModule, SemanticSymbol* currentSymbol, Scope* moduleScope, ref ModuleCache cache)
{
	with (CompletionKind) final switch (currentSymbol.acSymbol.kind)
	{
	case className:
	case interfaceName:
		resolveInheritance(currentSymbol.acSymbol, currentSymbol.typeLookups,
			moduleScope, cache);
		break;
	case withSymbol:
	case variableName:
	case memberVariableName:
	case functionName:
	case ufcsName:
	case aliasName:
		// type may not be null in the case of a renamed import
		if (currentSymbol.acSymbol.type is null)
		{
			resolveType(currentSymbol.acSymbol, currentSymbol.typeLookups,
				moduleScope, cache);
		}
		break;
	case importSymbol:
		if (currentSymbol.acSymbol.type is null)
			resolveImport(rootModule.acSymbol, currentSymbol.acSymbol, currentSymbol.typeLookups, cache);

		//warning("root: ", rootModule.acSymbol.symbolFile, " >import> ", currentSymbol.acSymbol.symbolFile, " public:", currentSymbol.acSymbol.skipOver == false);

		//auto importedFromSym = GCAllocator.instance.make!DSymbol("*public_imported*", CompletionKind.dummy, rootModule.acSymbol);
		//currentSymbol.acSymbol.addChild(importedFromSym, true);

		break;
	case variadicTmpParam:
		currentSymbol.acSymbol.type = variadicTmpParamSymbol;
		break;
	case typeTmpParam:
		currentSymbol.acSymbol.type = typeTmpParamSymbol;
		break;
	case structName:
	case unionName:
	case enumName:
	case keyword:
	case enumMember:
	case packageName:
	case moduleName:
	case dummy:
	case templateName:
	case mixinTemplateName:
		break;
	}

	// let's be methodic about the way we traverse symbols
	// so that childs have access to resolved symbols
	// functions should be last, because inside, there might be symbols that references
	// code from the parent not yet resolved (templates)
    if (currentSymbol && currentSymbol.children.length)
	foreach (child; currentSymbol.children)
		if (child.acSymbol.kind != CompletionKind.variableName && child.acSymbol.kind != CompletionKind.functionName)
			secondPass(rootModule, child, moduleScope, cache);

	foreach (child; currentSymbol.children)
		if (child.acSymbol.kind == CompletionKind.variableName)
			secondPass(rootModule, child, moduleScope, cache);

	foreach (child; currentSymbol.children)
		if (child.acSymbol.kind == CompletionKind.functionName)
			secondPass(rootModule, child, moduleScope, cache);

	// `alias T = typeof(x)` / `alias M = __traits(getMember, T, n)` resolve in
	// the first loop above, before the variables they name (second loop), so a
	// first attempt can forward to an as-yet-unresolved operand.  Retry the
	// suspicious ones now that every sibling resolved: idempotent for healthy
	// aliases, and a bounded fixpoint so `alias M` after `alias T` settles too.
	foreach (i; 0 .. 4)
	{
		bool progressed = false;
		foreach (child; currentSymbol.children)
		{
			if (child.acSymbol.kind != CompletionKind.aliasName
				|| !aliasNeedsRetry(child.acSymbol))
				continue;
			resolveType(child.acSymbol, child.typeLookups, moduleScope, cache);
			if (!aliasNeedsRetry(child.acSymbol))
				progressed = true;
		}
		if (!progressed)
			break;
	}


	// Alias this and mixin templates are resolved after child nodes are
	// resolved so that the correct symbol information will be available.
	with (CompletionKind) switch (currentSymbol.acSymbol.kind)
	{
	case className:
	case interfaceName:
	case structName:
	case unionName:
		resolveAliasThis(currentSymbol.acSymbol, currentSymbol.typeLookups, moduleScope, cache);
		resolveMixinTemplates(currentSymbol.acSymbol, currentSymbol.typeLookups,
			moduleScope, cache);
		break;
	default:
		break;
	}
}
void resolveImport(DSymbol* rootModule, DSymbol* acSymbol, ref TypeLookups typeLookups,
	ref ModuleCache cache)
in
{
	assert(acSymbol.kind == CompletionKind.importSymbol);
	assert(acSymbol.symbolFile !is null);
}
do
{

	DSymbol* moduleSymbol = cache.cacheModule(acSymbol.symbolFile);


	if (acSymbol.qualifier == SymbolQualifier.selectiveImport)
	{
		if (moduleSymbol is null)
		{
		tryAgain:
			DeferredSymbol* deferred = DeferredSymbolsAllocator.instance.make!DeferredSymbol(acSymbol);
			deferred.typeLookups.insert(typeLookups[]);
			// Get rid of the old references to the lookups, this new deferred
			// symbol owns them now
			typeLookups.clear();
			cache.deferredSymbols.insert(deferred);
		}
		else
		{
			// The bind's data, recorded by the producer: `import m : a;` binds
			// `a`, `import m : b = c;` binds `c` under the alias `b`.  It is
			// interned data rather than the `ImportBind` node because a
			// deferred import outlives the importing module's tree.
			immutable bool renamed = typeLookups.empty
				? false : typeLookups.front.selectiveImportRenamed;
			istring symbolName = typeLookups.empty
				? istring.init : typeLookups.front.selectiveImportName;
			DSymbol* selected = symbolName.length > 0
				? moduleSymbol.getFirstPartNamed(symbolName) : null;
			if (selected is null)
				goto tryAgain;
			acSymbol.type = selected;
			acSymbol.ownType = false;

			if (renamed)
			{
				acSymbol.kind = CompletionKind.aliasName;
				acSymbol.symbolFile = acSymbol.altFile().path;
			}

			// The bind's data has been used: the symbol points at the
			// declaration it binds now.  Keeping the lookup makes later
			// passes read this alias as something with a type expression of
			// its own (`resolveType` is handed every alias whose operand is
			// still unresolved), and a selective import has none - it used to
			// end in `resolveType`'s "How did this happen?" assertion, taking
			// the server down for any module that renamed a still-unresolved
			// symbol (`import std.traits : CoreUnconst = Unconst;`).
			typeLookups.clear();
		}
	}
	else
	{
		if (moduleSymbol is null)
		{
			DeferredSymbol* deferred = DeferredSymbolsAllocator.instance.make!DeferredSymbol(
				acSymbol);
			cache.deferredSymbols.insert(deferred);
		}
		else
		{
			acSymbol.type = moduleSymbol;
			acSymbol.ownType = false;
		}
	}
}

private:

void resolveType(DSymbol* symbol, ref TypeLookups typeLookups,
	Scope* moduleScope, ref ModuleCache cache, DSymbol*[string] mapping = null)
{
	// going through the lookups
	foreach(lookup; typeLookups) {
		if (lookup.kind == TypeLookupKind.varOrFunType)
			resolveTypeFromType(symbol, lookup, moduleScope, cache, null, mapping);
		else if (lookup.kind == TypeLookupKind.initializer
			|| lookup.kind == TypeLookupKind.foreachElement)
			resolveTypeFromInitializer(symbol, lookup, moduleScope, cache, mapping);
		// issue 94
		else if (lookup.kind == TypeLookupKind.inherit)
			resolveInheritance(symbol, typeLookups, moduleScope, cache, mapping);
		else
		{
			// A lookup kind with nothing to do here (a selective import is
			// resolved by `resolveImport`, an `alias this` by
			// `resolveAliasThis`).  It used to be an assertion, which turned
			// any such symbol into a dead language server - the log line is
			// the useful half of that.
			warning("unhandled lookup kind ", lookup.kind, " on symbol ",
				symbol.name, " (kind ", symbol.kind, ", ", symbol.symbolFile, ")");
			continue;
		}
		}
}


