/* Host-link support for VLC's production JSON parser probe. The parser,
 * grammar, tokeniser, and json_get_str implementation are compiled verbatim
 * from VLC. These wrappers only map VLC's charset ABI to the macOS iconv ABI. */

#include <errno.h>
#include <iconv.h>
#include <stdlib.h>

#include <vlc_common.h>
#include <vlc_charset.h>

vlc_iconv_t vlc_iconv_open(const char *to, const char *from)
{
    return (vlc_iconv_t)iconv_open(to, from);
}

size_t vlc_iconv(vlc_iconv_t handle, const char **input,
                 size_t *input_size, char **output, size_t *output_size)
{
    return iconv((iconv_t)handle, (char **)input, input_size,
                 output, output_size);
}

int vlc_iconv_close(vlc_iconv_t handle)
{
    return iconv_close((iconv_t)handle);
}

char *FromCharset(const char *charset, const void *data, size_t data_size)
{
    vlc_iconv_t handle = vlc_iconv_open("UTF-8", charset);
    if (handle == (vlc_iconv_t)-1)
        return NULL;

    char *result = NULL;
    for (unsigned multiplier = 4; multiplier < 8; ++multiplier)
    {
        size_t input_size = data_size;
        const char *input = data;
        size_t output_size = multiplier * data_size;
        char *output = result = malloc(1 + output_size);
        if (result == NULL)
            break;

        if (vlc_iconv(handle, &input, &input_size, &output, &output_size)
                != (size_t)-1)
        {
            *output = '\0';
            break;
        }

        free(result);
        result = NULL;
        if (errno != E2BIG)
            break;
    }

    vlc_iconv_close(handle);
    return result;
}
