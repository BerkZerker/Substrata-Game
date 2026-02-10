# TODO

- Check over and clean up the chunk editing code and make sure everything functions correctly and efficiently when modifying terrain, especially with large edits - check for lag spikes.

- Figure out a solution to the reference problem, the player and input manager need access to the chunk manager, perhaps a bus node in the game instance? I need to research if there are any already existing solutions. I also need to keep my code clean and well compartmentalized - each file should have a specific purpose and keep the logic internalized, high complexity within files, low complexity between different scripts.

- Clean up the debug overlay code and make it a bit more refined, add some debugging info to the main scene and add proper keybindings to toggle it in the project settings.

- Implement the WorkerThreadPool for generation, editing, loading and saving of chunks to improve performance and reduce lag spikes during gameplay. Pre-instance all chunk scenes and reuse them to reduce instancing overhead.

- Check over all my recent edits with Claude & myself to make sure the AI generated code is up to my standards and refactor as needed before introducing integrated profiling and documentation.

- Update `README.md` and add some basic documentation and at least 1 screenshot - maybe once I have actual terrain working that isn't just simplex noise.

- Build a movement controller for testing terrain interaction - walking, jumping, falling, and colliding with terrain, this will come in handy when adding more entities besides the player and keep the player clean.

- Consider moving to a component-based system when appliciable - so far I'm thinking stuff like entities, terrain generation, and items in the future.

- Overall, futureproof the codebase and strcutre, making sure the code is: extendable in the future, readable, maintainable, efficient, well documented and of course, actually works.
