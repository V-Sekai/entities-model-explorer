# Motion clips

`clips.tsv` is the motion list: one clip per line, `key TAB loop|once TAB seconds TAB prompt`.
A loop's seconds is the length to look for (the cut takes the clip's own cycle near it); a
one-shot keeps its whole action. `<key>.f32` is the prompt's text input for Kimodo: 4096 floats
from the LLM2Vec Llama-3 text encoder (`chibifire/Llama-3-Kimodo-GGML`), made once with
interactor-motion-guest `tools/motion_native embed`, because the 15 GB encoder does not ship.
To change a prompt, embed it again and replace its file.
