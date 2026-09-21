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

module dcd.common.messages;


/**
 * The type of completion list being returned
 */
enum CompletionType : string
{
	/**
	 * The completion list contains a listing of identifier/kind pairs.
	 */
	identifiers = "identifiers",

	/**
	 * The auto-completion list consists of a listing of functions and their
	 * parameters.
	 */
	calltips = "calltips",

	/**
	 * The response contains the location of a symbol declaration.
	 */
	location = "location",

	/**
	 * The response contains documentation comments for the symbol.
	 */
	ddoc = "ddoc",

	/**
	 * The completion list contains a listing of struct members for designated initialization.
	 */
	structMembers = "structMembers",
}

/**
 * Request kind
 */
enum RequestKind : ushort
{
	// dfmt off
	uninitialized =  0b00000000_00000000,
	/// Autocompletion
	autocomplete =   0b00000000_00000001,
	/// Clear the completion cache
	clearCache =     0b00000000_00000010,
	/// Add import directory to server
	addImport =      0b00000000_00000100,
	/// Shut down the server
	shutdown =       0b00000000_00001000,
	/// Get declaration location of given symbol
	symbolLocation = 0b00000000_00010000,
	/// Get the doc comments for the symbol
	doc =            0b00000000_00100000,
	/// Query server status
	query =	         0b00000000_01000000,
	/// Search for symbol
	search =         0b00000000_10000000,
	/// List import directories
	listImports =    0b00000001_00000000,
	/// Local symbol usage
	localUse =     	 0b00000010_00000000,
	/// Remove import directory from server
	removeImport =   0b00000100_00000000,
    /// Get inlay hints
	inlayHints =     0b00001000_00000000,
    /// Get symbol details
	symbolDetails =  0b00010000_00000000,
    /// Get function calltips
	extractCalltips =0b00100000_00000000,

	/// These request kinds require source code and won't be executed if there
	/// is no source sent
	requiresSourceCode = autocomplete | doc | symbolLocation | search | localUse | inlayHints | symbolDetails | extractCalltips,
	// dfmt on
}

/**
 * Autocompletion request message
 */
struct AutocompleteRequest
{
	/**
	 * File name used for error reporting
	 */
	string fileName;

	/**
	 * Command coming from the client
	 */
	RequestKind kind;

	/**
	 * Paths to be searched for import files
	 */
	string[] importPaths;

	/**
	 * The source code to auto complete
	 */
	ubyte[] sourceCode;

	/**
	 * The cursor position
	 */
	size_t cursorPosition;

	/**
	 * Name of symbol searched for
	 */
	string searchName;
}

/**
 * Autocompletion response message
 */
struct AutocompleteResponse
{
	static struct Completion
	{
		/**
		 * The name of the symbol for a completion, for calltips just the function name.
		 */
		string identifier;
		/**
		 * The kind of the item. Will be char.init for calltips.
		 */
		ubyte kind;
		/**
		 * Definition for a symbol for a completion including attributes or the arguments for calltips.
		 */
		string definition;
		/**
		 * The path to the file that contains the symbol.
		 */
		string symbolFilePath;
		/**
		 * The byte offset at which the symbol is located or symbol location for symbol searches.
		 */
		size_t symbolLocation;
		/**
		 * Documentation associated with this symbol.
		 */
		string documentation;
		// when changing the behavior here, update README.md
		/**
		 * For variables, fields, globals, constants: resolved type or empty if unresolved.
		 * For functions: resolved return type or empty if unresolved.
		 * For constructors: may be struct/class name or empty in any case.
		 * Otherwise (probably) empty.
		 */
		string typeOf;
	}

	/**
	 * The autocompletion type. (Parameters or identifier)
	 */
	string completionType;

	/**
	 * The path to the file that contains the symbol.
	 */
	string symbolFilePath;

	/**
	 * The byte offset at which the symbol is located.
	 */
	size_t symbolLocation;

	/**
	 * The completions
	 */
	Completion[] completions;

	/**
	 * Import paths that are registered by the server.
	 */
	string[] importPaths;

	/**
	 * Symbol identifier
	 */
	ulong symbolIdentifier;

	/**
	 * Creates an empty acknowledgement response
	 */
	static AutocompleteResponse ack()
	{
		AutocompleteResponse response;
		response.completionType = "ack";
		return response;
	}
}

