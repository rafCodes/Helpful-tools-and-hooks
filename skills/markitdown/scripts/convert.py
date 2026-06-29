import sys
from markitdown import MarkItDown

result = MarkItDown().convert(sys.argv[1])
print(result.text_content)
