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

/**
 * Resolves a symbol's base classes/interfaces (`class D : Base`), `alias
 * this`, and mixin templates -- run after a symbol's own children have
 * resolved (see `secondPass` in `dsymbol.conversion.second`) so the correct
 * symbol information is available.
 */
module dsymbol.conversion.second.inheritance;

import dsymbol.conversion.second.declared_type : identifierName;
import dsymbol.conversion.second.instantiate : instantiateFromNode;
import dsymbol.semantic : TypeLookups;
import dsymbol.symbol;
import dsymbol.scope_;
import dsymbol.string_interning;
import dsymbol.builtin.names;
import dsymbol.type_lookup;
import dsymbol.modulecache;
import std.experimental.allocator;
import std.experimental.allocator.gc_allocator : GCAllocator;
import dparse.ast;
import dparse.lexer;
import std.algorithm : filter;

package void resolveInheritance(DSymbol* symbol, ref TypeLookups typeLookups,
	Scope* moduleScope, ref ModuleCache cache, DSymbol*[string] mapping = null)
{
	outer: foreach (TypeLookup* lookup; typeLookups[])
	{
		if (lookup.kind != TypeLookupKind.inherit)
			continue;
		// The base class name chain comes from the `BaseClass` node the
		// producer recorded (`writeIotcTo` used to spell it into crumbs).
		auto bc = cast(const(BaseClass)) lookup.astNode;
		if (bc is null || bc.type2 is null || bc.type2.typeIdentifierPart is null)
			continue;

		// TODO: Delayed type lookup
		auto symbolScope = moduleScope.getScopeByCursor(
			symbol.location + symbol.name.length);

		DSymbol* baseClass;
		bool first = true;
		for (TypeIdentifierPart part = cast() bc.type2.typeIdentifierPart; part !is null;
			part = part.typeIdentifierPart)
		{
			auto name = identifierName(part);
			if (name.length == 0)
				continue outer;
			if (first)
			{
				if (name.data in mapping)
					baseClass = mapping[name.data];
				else
				{
					auto symbols = moduleScope.getSymbolsByNameAndCursor(name,
						symbol.location);
					if (symbols.length == 0)
						continue outer;
					baseClass = symbols[0];
				}
				first = false;
			}
			else
			{
				auto symbols = baseClass.getPartsByName(name);
				if (symbols.length == 0)
					continue outer;
				baseClass = symbols[0];
			}

			// `class Derived(T) : Base!T` -- the arguments written at the
			// inheritance site, applied the same way a declared type applies
			// its head instance.  Without them the child would import the
			// generic `Base` and the base's members would keep the parameter.
			if (part.identifierOrTemplateInstance !is null
				&& part.identifierOrTemplateInstance.templateInstance !is null)
				baseClass = instantiateFromNode(baseClass,
					part.identifierOrTemplateInstance.templateInstance,
					part.identifierOrTemplateInstance.tokens, symbol, moduleScope, cache,
					mapping);
		}
		if (baseClass is null)
			continue;

		DSymbol* imp = GCAllocator.instance.make!DSymbol(IMPORT_SYMBOL_NAME,
			CompletionKind.importSymbol, baseClass);
		symbol.addChild(imp, true);
		symbolScope.addSymbol(imp, false);
		if (baseClass.kind == CompletionKind.className)
		{
			auto s = GCAllocator.instance.make!DSymbol(SUPER_SYMBOL_NAME,
				CompletionKind.variableName, baseClass);
			symbolScope.addSymbol(s, true);
		}
	}
}

package void resolveAliasThis(DSymbol* symbol,
	ref TypeLookups typeLookups, Scope* moduleScope, ref ModuleCache cache, DSymbol*[string] mapping = null)
{
	foreach (aliasThis; typeLookups[].filter!(a => a.kind == TypeLookupKind.aliasThis))
	{
		auto dec = cast(const(AliasThisDeclaration)) aliasThis.astNode;
		if (dec is null || dec.identifier == tok!"")
			continue;
		auto parts = symbol.getPartsByName(internString(dec.identifier.text));
		if (parts.length == 0 || parts[0].type is null)
			continue;

		DSymbol* s = GCAllocator.instance.make!DSymbol(IMPORT_SYMBOL_NAME,
			CompletionKind.importSymbol, parts[0].type);
		symbol.addChild(s, true);
		auto symbolScope = moduleScope.getScopeByCursor(s.location);
		if (symbolScope !is null)
			symbolScope.addSymbol(s, false);
	}
}

package void resolveMixinTemplates(DSymbol* symbol,
	ref TypeLookups typeLookups, Scope* moduleScope, ref ModuleCache cache, DSymbol*[string] mapping = null)
{
	foreach (mix; typeLookups[].filter!(a => a.kind == TypeLookupKind.mixinTemplate))
	{
		// The mixin template's name chain comes from the node the producer
		// recorded (`writeIotcTo` used to spell it into crumbs).
		auto chain = cast(const(IdentifierOrTemplateChain)) mix.astNode;
		if (chain is null || chain.identifiersOrTemplateInstances.length == 0)
			continue;

		DSymbol* currentSymbol;
		bool first = true;
		foreach (ioti; chain.identifiersOrTemplateInstances)
		{
			auto name = identifierName(ioti);
			if (name.length == 0)
			{
				currentSymbol = null;
				break;
			}
			if (first)
			{
				if (name.data in mapping)
					currentSymbol = mapping[name.data];
				else
				{
					auto symbols = moduleScope.getSymbolsByNameAndCursor(name,
						symbol.location);
					if (symbols.length == 0)
					{
						currentSymbol = null;
						break;
					}
					currentSymbol = symbols[0];
				}
				first = false;
			}
			else
			{
				auto s = currentSymbol.getPartsByName(name);
				if (s.length == 0)
				{
					currentSymbol = null;
					break;
				}
				currentSymbol = s[0];
			}

			// `mixin Extra!T;` -- the mixin template's own arguments, so the
			// symbols it contributes follow this declaration's parameters.
			if (currentSymbol !is null && ioti.templateInstance !is null)
				currentSymbol = instantiateFromNode(currentSymbol, ioti.templateInstance,
					ioti.tokens, symbol, moduleScope, cache, mapping);
		}
		if (currentSymbol !is null)
		{
			auto i = GCAllocator.instance.make!DSymbol(IMPORT_SYMBOL_NAME,
				CompletionKind.importSymbol, currentSymbol);
			i.ownType = false;
			symbol.addChild(i, true);
		}
	}
}
